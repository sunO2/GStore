//! Extern "C" callbacks of the mock host vtable.

use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::atomic::Ordering;

use gstore_contract::abi::{ByteBuf, ABI_ERR_CONFIG_INVALID, ABI_ERR_CONFIG_NOT_FOUND, ABI_OK};
use serde_json::{json, Value};

use super::{Callback, MockHost, MockSubscription};
use crate::config;

fn registry_default(module: &str, key: &str) -> Option<Value> {
    match (module, key) {
        ("download", config::KEY_MULTI_SEGMENT_ENABLED) => Some(json!(true)),
        ("download", config::KEY_MAX_CONCURRENT) => Some(json!(3)),
        ("download", config::KEY_DEFAULT_CONNECTIONS) => Some(json!(4)),
        ("download", config::KEY_MAX_RETRIES) => Some(json!(3)),
        ("download", config::KEY_SPEED_LIMIT_BPS) => Some(json!(0)),
        ("download", config::KEY_WIFI_ONLY) => Some(json!(false)),
        (config::MODULE_NETWORK, config::KEY_PROXY_URL) => Some(json!("")),
        _ => None,
    }
}

unsafe fn host_ref<'a>(ctx: *mut c_void) -> &'a MockHost {
    &*(ctx as *const MockHost)
}

fn opt_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}

fn put_json(out: *mut ByteBuf, text: &str) {
    if out.is_null() {
        return;
    }
    let bytes = text.as_bytes().to_vec().into_boxed_slice();
    let len = bytes.len();
    let ptr = Box::into_raw(bytes) as *mut u8;
    unsafe { *out = ByteBuf { ptr, len } };
}

pub(super) extern "C" fn mock_get(
    ctx: *mut c_void,
    module_or_null: *const c_char,
    key: *const c_char,
    out_json: *mut ByteBuf,
) -> c_int {
    let host = unsafe { host_ref(ctx) };
    let module = opt_str(module_or_null).unwrap_or_else(|| config::MODULE.to_string());
    let Some(key) = opt_str(key) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    host.calls
        .lock()
        .unwrap()
        .push(format!("get:{module}:{key}"));
    let value = host
        .store
        .lock()
        .unwrap()
        .get(&(module.clone(), key.clone()))
        .cloned()
        .or_else(|| registry_default(&module, &key));
    let Some(value) = value else {
        return ABI_ERR_CONFIG_NOT_FOUND;
    };
    put_json(out_json, &serde_json::to_string(&value).unwrap());
    ABI_OK
}

pub(super) extern "C" fn mock_set(
    ctx: *mut c_void,
    key: *const c_char,
    value_json: *const c_char,
) -> c_int {
    let host = unsafe { host_ref(ctx) };
    let Some(key) = opt_str(key) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    let Some(text) = opt_str(value_json) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    host.calls
        .lock()
        .unwrap()
        .push(format!("set:{}:{key}", config::MODULE));
    host.set_value(&config::MODULE.to_string(), &key, value);
    ABI_OK
}

pub(super) extern "C" fn mock_list(
    _ctx: *mut c_void,
    _module_or_null: *const c_char,
    out_json: *mut ByteBuf,
) -> c_int {
    put_json(out_json, "[]");
    ABI_OK
}

pub(super) extern "C" fn mock_subscribe(
    ctx: *mut c_void,
    module_or_null: *const c_char,
    key_or_null: *const c_char,
    user_ctx: *mut c_void,
    callback: Option<Callback>,
    out_token: *mut u64,
) -> c_int {
    let host = unsafe { host_ref(ctx) };
    let module = opt_str(module_or_null).unwrap_or_else(|| config::MODULE.to_string());
    let key = opt_str(key_or_null);
    let Some(callback) = callback else {
        return ABI_ERR_CONFIG_INVALID;
    };
    if out_token.is_null() {
        return ABI_ERR_CONFIG_INVALID;
    }
    host.calls.lock().unwrap().push(format!(
        "subscribe:{module}:{}",
        key.as_deref().unwrap_or("*")
    ));
    let token = host.next_token.fetch_add(1, Ordering::SeqCst);
    host.subscriptions.lock().unwrap().push(MockSubscription {
        token,
        module,
        key,
        user: user_ctx as usize,
        callback,
    });
    unsafe { *out_token = token };
    host.flush_pending();
    ABI_OK
}

pub(super) extern "C" fn mock_unsubscribe(ctx: *mut c_void, token: u64) -> c_int {
    let host = unsafe { host_ref(ctx) };
    let before = host.subscriptions.lock().unwrap().len();
    host.subscriptions
        .lock()
        .unwrap()
        .retain(|s| s.token != token);
    if host.subscriptions.lock().unwrap().len() == before {
        gstore_contract::abi::ABI_ERR_CONFIG_BAD_TOKEN
    } else {
        ABI_OK
    }
}

pub(super) extern "C" fn mock_free_buf(buf: ByteBuf) {
    if buf.ptr.is_null() {
        return;
    }
    // SAFETY: `put_json` leaked a `Box<[u8]>` with len == capacity.
    unsafe { drop(Vec::from_raw_parts(buf.ptr, buf.len, buf.len)) };
}
