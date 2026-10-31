//! ABI v5 configuration vtable access for the download module.
//!
//! The Rust config store owned by the host is the **single authority**; this
//! module never persists configuration itself. Everything here is a thin,
//! defensive wrapper around [`GStoreConfigApiV1`]:
//!
//! - [`get`] reads through the bound vtable (`module = NULL` means "own module").
//! - [`set`] writes own-module keys (the host is authoritative and publishes the
//!   resulting change, which we receive through our subscription).
//! - [`subscribe`] / [`unsubscribe`] manage the module-lifetime subscriptions.
//!
//! Every value crossing the ABI is parsed with a *typed* expectation. A
//! malformed value never escapes as a panic and never overwrites the previous
//! setting: the `parse_*` helpers return `None`, and the caller keeps the old
//! value.
//!
//! ## Keys consumed by this module (Todo 4 registry)
//!
//! | key | scheduler knob | precedence |
//! |---|---|---|
//! | `download.multi_segment.enabled` | `SchedulerConfig::multi_segment_enabled` | `false` ⇒ effective connections = 1 |
//! | `download.max_concurrent` | `SchedulerConfig::max_concurrent` | 1..=10, validated by the host schema |
//! | `download.default_connections` | `SchedulerConfig::default_connections` | only used when multi-segment is enabled |
//! | `download.max_retries` | `SchedulerConfig::max_retries` | 0..=5 |
//! | `download.speed_limit_bps` | `SchedulerConfig::speed_limit_bps` | `0` ⇒ unlimited |
//! | `network.proxy_url` (`PublicRead`) | observability only | read once; **not applied** by this module |
//!
//! `download.wifi_only` is intentionally **not** consumed here — it is a
//! Dart-side connectivity preference with no engine counterpart. The key stays
//! registered so the settings page and the migration tool still own it.
//!
//! Segment sizing is not configurable through this module: no such key is
//! registered, and the engine derives segment sizing internally.

mod keys;
mod model;

pub use keys::*;
pub use model::*;

use std::ffi::{c_char, c_int, c_void, CString};

use gstore_contract::abi::{
    ByteBuf, GStoreConfigApiV1, ABI_ERR_CONFIG_INVALID, ABI_OK, CONFIG_CAP_GET, CONFIG_CAP_SET,
    CONFIG_CAP_SUBSCRIBE,
};
use serde_json::Value;

/// Callback type used by [`GStoreConfigApiV1::subscribe`].
pub type ChangeCallback = extern "C" fn(user_ctx: *mut c_void, change_json: *const c_char) -> c_int;

/// Whether the vtable exposes the capability this module requires to be usable.
pub fn is_usable(api: &GStoreConfigApiV1) -> bool {
    api.has_capability(CONFIG_CAP_GET)
}

/// True when the vtable advertises the write capability (used by `download.config`).
pub fn can_write(api: &GStoreConfigApiV1) -> bool {
    api.has_capability(CONFIG_CAP_SET)
}

fn c_string(text: &str) -> Result<CString, c_int> {
    CString::new(text).map_err(|_| ABI_ERR_CONFIG_INVALID)
}

fn opt_c_string(text: Option<&str>) -> Result<Option<CString>, c_int> {
    text.map(c_string).transpose()
}

fn read_buf(api: &GStoreConfigApiV1, buf: ByteBuf) -> Option<String> {
    if buf.ptr.is_null() || buf.len == 0 {
        return None;
    }
    // SAFETY: the host allocated `buf.ptr` with `buf.len` readable bytes and the
    // vtable contract hands ownership back through `free_buf`; we copy first so
    // the buffer may be freed immediately afterwards.
    let bytes = unsafe { std::slice::from_raw_parts(buf.ptr, buf.len) }.to_vec();
    let text = String::from_utf8(bytes).ok();
    if let Some(free) = api.free_buf {
        free(buf);
    }
    text
}

/// Reads `key` in `module` (`None` = own module). `Ok(None)` covers JSON `null`.
pub fn get(
    api: &GStoreConfigApiV1,
    module: Option<&str>,
    key: &str,
) -> Result<Option<Value>, c_int> {
    let Some(get) = api.get else {
        return Err(ABI_ERR_CONFIG_INVALID);
    };
    let key = c_string(key)?;
    let module = opt_c_string(module)?;
    let mut out = ByteBuf {
        ptr: std::ptr::null_mut(),
        len: 0,
    };
    let rc = get(
        api.context,
        module.as_ref().map_or(std::ptr::null(), |m| m.as_ptr()),
        key.as_ptr(),
        &mut out,
    );
    if rc != ABI_OK {
        return Err(rc);
    }
    let Some(text) = read_buf(api, out) else {
        return Ok(None);
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|_| ABI_ERR_CONFIG_INVALID)
}

/// Reads one of the module's own keys.
pub fn get_own(api: &GStoreConfigApiV1, key: &str) -> Result<Option<Value>, c_int> {
    get(api, None, key)
}

/// Writes one of the module's own keys through the bound vtable.
pub fn set(api: &GStoreConfigApiV1, key: &str, value: &Value) -> Result<(), c_int> {
    let Some(set) = api.set else {
        return Err(ABI_ERR_CONFIG_INVALID);
    };
    let key = c_string(key)?;
    let json = serde_json::to_string(value).map_err(|_| ABI_ERR_CONFIG_INVALID)?;
    let value = c_string(&json)?;
    let rc = set(api.context, key.as_ptr(), value.as_ptr());
    if rc == ABI_OK {
        Ok(())
    } else {
        Err(rc)
    }
}

/// Subscribes to changes (`module = None` = own module, `key = None` = whole module).
pub fn subscribe(
    api: &GStoreConfigApiV1,
    module: Option<&str>,
    key: Option<&str>,
    callback: ChangeCallback,
) -> Result<u64, c_int> {
    if !api.has_capability(CONFIG_CAP_SUBSCRIBE) {
        return Err(ABI_ERR_CONFIG_INVALID);
    }
    let Some(subscribe) = api.subscribe else {
        return Err(ABI_ERR_CONFIG_INVALID);
    };
    let module = opt_c_string(module)?;
    let key = opt_c_string(key)?;
    let mut token = 0u64;
    let rc = subscribe(
        api.context,
        module.as_ref().map_or(std::ptr::null(), |m| m.as_ptr()),
        key.as_ref().map_or(std::ptr::null(), |k| k.as_ptr()),
        std::ptr::null_mut(),
        Some(callback),
        &mut token,
    );
    if rc == ABI_OK {
        Ok(token)
    } else {
        Err(rc)
    }
}

/// Cancels a token created by this module.
pub fn unsubscribe(api: &GStoreConfigApiV1, token: u64) -> Result<(), c_int> {
    let Some(unsubscribe) = api.unsubscribe else {
        return Err(ABI_ERR_CONFIG_INVALID);
    };
    let rc = unsubscribe(api.context, token);
    if rc == ABI_OK {
        Ok(())
    } else {
        Err(rc)
    }
}

/// Reads every knob this module consumes, keeping defaults for unreadable keys.
///
/// Called **after** the subscriptions are installed so a change committed
/// during the subscribe/read window cannot be lost.
pub fn read_snapshot(api: &GStoreConfigApiV1) -> ModuleConfig {
    let mut cfg = ModuleConfig::default();

    if let Ok(Some(v)) = get_own(api, KEY_MULTI_SEGMENT_ENABLED) {
        if let Some(parsed) = parse_bool(&v) {
            cfg.multi_segment_enabled = parsed;
        }
    }
    if let Ok(Some(v)) = get_own(api, KEY_MAX_CONCURRENT) {
        if let Some(parsed) = parse_max_concurrent(&v) {
            cfg.max_concurrent = parsed;
        }
    }
    if let Ok(Some(v)) = get_own(api, KEY_DEFAULT_CONNECTIONS) {
        if let Some(parsed) = parse_default_connections(&v) {
            cfg.default_connections = parsed;
        }
    }
    if let Ok(Some(v)) = get_own(api, KEY_MAX_RETRIES) {
        if let Some(parsed) = parse_max_retries(&v) {
            cfg.max_retries = parsed;
        }
    }
    if let Ok(Some(v)) = get_own(api, KEY_SPEED_LIMIT_BPS) {
        if let Some(parsed) = parse_speed_limit(&v) {
            cfg.speed_limit_bps = parsed;
        }
    }
    if let Ok(Some(v)) = get(api, Some(MODULE_NETWORK), KEY_PROXY_URL) {
        if let Some(parsed) = parse_proxy_url(&v) {
            cfg.proxy_url = parsed;
        }
    }

    cfg
}
