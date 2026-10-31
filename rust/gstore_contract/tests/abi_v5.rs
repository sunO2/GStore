//! ABI v5 config vtable + real v4 `.so` fixture tests.
//!
//! The v4 fixture is compiled from `tests/fixtures/v4_module.c` at test time
//! (no committed binary, no network/device). The mock host below implements the
//! visibility/ownership contract from `abi.rs` so the vtable round-trips
//! through real function-pointer calls.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::mem::MaybeUninit;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};

use gstore_contract::abi::{
    host_abi_satisfies, ByteBuf, GStoreConfigApiV1, GStoreConfigContextV1, GStoreModuleApi,
    GStoreModuleEntry, ABI_ERR_CONFIG_BAD_TOKEN, ABI_ERR_CONFIG_FORBIDDEN, ABI_ERR_CONFIG_INVALID,
    ABI_ERR_CONFIG_NOT_FOUND, ABI_OK, CONFIG_CAP_ALL, CONFIG_CAP_GET, CONFIG_CAP_LIST,
    CONFIG_CAP_SET, CONFIG_CAP_SUBSCRIBE, GSTORE_MODULE_ABI_VERSION,
};

type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type AbiProbeFn = extern "C" fn() -> u32;
type ChangeCb = extern "C" fn(*mut c_void, *const c_char) -> c_int;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/abi_v5_fixtures")
}

/// Compile the C fixture into a unique `.so` named after the module.
fn build_fixture(module: &str, min_host_abi: u32) -> PathBuf {
    let dir = fixture_dir();
    std::fs::create_dir_all(&dir).expect("create fixture dir");
    let out = dir.join(format!("libgstore_mod_{module}.so"));
    let src = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/v4_module.c");
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let status = std::process::Command::new(cc)
        .args(["-shared", "-fPIC", "-std=c99", "-Wall", "-Wextra", "-Werror"])
        .arg(format!("-DFIXTURE_MIN_HOST_ABI={min_host_abi}"))
        .arg("-o")
        .arg(&out)
        .arg(&src)
        .status()
        .expect("spawn C compiler for ABI v4 fixture");
    assert!(status.success(), "C fixture compile failed: {status}");
    out
}

fn dlopen(path: &Path) -> libloading::Library {
    unsafe { libloading::Library::new(path) }
        .unwrap_or_else(|e| panic!("dlopen {}: {e}", path.display()))
}

/// A genuine ABI v4 host entry: v4 `abi_version`, v4 size (through `platform`),
/// no `config` slot. On x86_64 `entry_size == 64`.
fn v4_host_entry() -> GStoreModuleEntry {
    GStoreModuleEntry {
        abi_version: 4,
        entry_size: GStoreModuleEntry::CONFIG_OFFSET as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: null_mut(),
        protect_fd: None,
        platform: null(),
        config: null(),
    }
}

#[test]
fn v4_fixture_loads_as_v4_without_config() {
    let so = build_fixture("v4demo", 3);
    let lib = dlopen(&so);

    let probe: libloading::Symbol<AbiProbeFn> = unsafe {
        lib.get(b"gstore_mod_v4demo_abi\0")
            .expect("v4 fixture must export its ABI probe")
    };
    let register: libloading::Symbol<RegisterFn> = unsafe {
        lib.get(b"gstore_mod_v4demo_register\0")
            .expect("v4 fixture must export register")
    };

    let probe_abi = probe();
    assert_eq!(probe_abi, 4, "fixture probe must report its build ABI 4");

    let entry = v4_host_entry();
    assert_eq!(
        entry.entry_size as usize,
        GStoreModuleEntry::CONFIG_OFFSET,
        "a v4 host entry stops before the config slot"
    );
    assert!(!entry.has_config(), "v4-sized entry must be rejected by has_config()");
    assert!(
        entry.config_if_present().is_none(),
        "v4-sized entry must expose no config vtable"
    );

    let mut api = MaybeUninit::<GStoreModuleApi>::zeroed();
    let rc = register(&entry, api.as_mut_ptr());
    assert_eq!(rc, ABI_OK, "v4 fixture must handshake with a v4 host entry");
    let api = unsafe { api.assume_init() };
    let name = unsafe { CStr::from_ptr(api.name) }.to_str().unwrap();
    assert_eq!(name, "v4demo");
    assert_eq!(api.min_host_abi, 3);

    println!(
        "[manual-qa] v4 fixture: probe_abi={} host_layout_abi={} v4_entry_size={} full_v5_entry_size={} has_config={} config_if_present_is_none={}",
        probe_abi,
        GSTORE_MODULE_ABI_VERSION,
        entry.entry_size,
        std::mem::size_of::<GStoreModuleEntry>(),
        entry.has_config(),
        entry.config_if_present().is_none()
    );
}

#[test]
fn v5_only_module_is_rejected_on_v4_host() {
    let so = build_fixture("v4only", 5);
    let lib = dlopen(&so);

    let probe: libloading::Symbol<AbiProbeFn> = unsafe {
        lib.get(b"gstore_mod_v4demo_abi\0")
            .expect("probe symbol")
    };
    let register: libloading::Symbol<RegisterFn> = unsafe {
        lib.get(b"gstore_mod_v4demo_register\0")
            .expect("register symbol")
    };
    assert_eq!(probe(), 4, "the v5-only module is still built with layout ABI 4");

    let entry = v4_host_entry();
    let mut api = MaybeUninit::<GStoreModuleApi>::zeroed();
    assert_eq!(register(&entry, api.as_mut_ptr()), ABI_OK);
    let api = unsafe { api.assume_init() };

    assert_eq!(api.min_host_abi, 5, "config-consuming module must demand ABI 5");
    let rejected = !host_abi_satisfies(api.min_host_abi, entry.abi_version);
    assert!(
        rejected,
        "a min_host_abi=5 module must be rejected by a v4 host at probe time"
    );

    println!(
        "[manual-qa] v5-only module: probe_abi=4 min_host_abi={} host_abi={} rejected={}",
        api.min_host_abi, entry.abi_version, rejected
    );
}

// ---------------------------------------------------------------------------
// Mock host implementing the vtable contract (visibility, ownership, tokens).
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Vis {
    Owner,
    PublicRead,
    Secret,
}

struct Entry {
    module: &'static str,
    key: &'static str,
    value: String,
    vis: Vis,
}

#[derive(Clone)]
struct Sub {
    owner: String,
    module: String,
    key: Option<String>,
    user_ctx: usize,
    cb: ChangeCb,
    token: u64,
}

struct Host {
    entries: Vec<Entry>,
    subs: Vec<Sub>,
    next_token: u64,
}

struct Bound {
    ctx: Box<GStoreConfigContextV1>,
    _name: CString,
    host: Box<Host>,
}

fn bind(module: &str, host: Host) -> Bound {
    let name = CString::new(module).expect("module name");
    let mut host = Box::new(host);
    let ctx = Box::new(GStoreConfigContextV1 {
        module_id: 1,
        module_name: name.as_ptr(),
        host: (&mut *host as *mut Host).cast(),
    });
    Bound {
        ctx,
        _name: name,
        host,
    }
}

fn ctx_ptr(bound: &Bound) -> *mut c_void {
    (&*bound.ctx as *const GStoreConfigContextV1).cast_mut().cast()
}

unsafe fn host_of<'a>(ctx: *mut c_void) -> (&'a GStoreConfigContextV1, &'a mut Host) {
    let binding = &*(ctx as *const GStoreConfigContextV1);
    let host = &mut *(binding.host as *mut Host);
    (binding, host)
}

fn caller_of(binding: &GStoreConfigContextV1) -> String {
    unsafe { CStr::from_ptr(binding.module_name) }
        .to_str()
        .unwrap_or("")
        .to_string()
}

unsafe fn opt_str(p: *const c_char) -> Result<Option<String>, c_int> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p)
        .to_str()
        .map(|s| Some(s.to_string()))
        .map_err(|_| ABI_ERR_CONFIG_INVALID)
}

fn put_json(out: *mut ByteBuf, json: &str) {
    if out.is_null() {
        return;
    }
    let boxed = json.as_bytes().to_vec().into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    unsafe { *out = ByteBuf { ptr, len } };
}

fn visible_to(entry: &Entry, caller: &str) -> bool {
    entry.module == caller || entry.vis == Vis::PublicRead
}

extern "C" fn cfg_get(
    ctx: *mut c_void,
    module: *const c_char,
    key: *const c_char,
    out: *mut ByteBuf,
) -> c_int {
    if out.is_null() {
        return ABI_ERR_CONFIG_INVALID;
    }
    unsafe { *out = ByteBuf { ptr: null_mut(), len: 0 } };
    let (binding, host) = unsafe { host_of(ctx) };
    let caller = caller_of(binding);
    let target = match unsafe { opt_str(module) } {
        Ok(Some(m)) => m,
        Ok(None) => caller.clone(),
        Err(e) => return e,
    };
    let key = match unsafe { opt_str(key) } {
        Ok(Some(k)) => k,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let Some(entry) = host
        .entries
        .iter()
        .find(|e| e.module == target && e.key == key)
    else {
        return ABI_ERR_CONFIG_NOT_FOUND;
    };
    if !visible_to(entry, &caller) {
        return ABI_ERR_CONFIG_FORBIDDEN;
    }
    put_json(out, &entry.value);
    ABI_OK
}

extern "C" fn cfg_set(ctx: *mut c_void, key: *const c_char, value_json: *const c_char) -> c_int {
    let (binding, host) = unsafe { host_of(ctx) };
    let caller = caller_of(binding);
    let key = match unsafe { opt_str(key) } {
        Ok(Some(k)) => k,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let value = match unsafe { opt_str(value_json) } {
        Ok(Some(v)) => v,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let Some(entry) = host
        .entries
        .iter_mut()
        .find(|e| e.module == caller && e.key == key)
    else {
        return ABI_ERR_CONFIG_NOT_FOUND;
    };
    entry.value = value;
    ABI_OK
}

extern "C" fn cfg_list(ctx: *mut c_void, module: *const c_char, out: *mut ByteBuf) -> c_int {
    if out.is_null() {
        return ABI_ERR_CONFIG_INVALID;
    }
    unsafe { *out = ByteBuf { ptr: null_mut(), len: 0 } };
    let (binding, host) = unsafe { host_of(ctx) };
    let caller = caller_of(binding);
    let target = match unsafe { opt_str(module) } {
        Ok(Some(m)) => m,
        Ok(None) => caller.clone(),
        Err(e) => return e,
    };
    let items: Vec<String> = host
        .entries
        .iter()
        .filter(|e| e.module == target && visible_to(e, &caller))
        .map(|e| format!(r#"{{"key":"{}","value":{}}}"#, e.key, e.value))
        .collect();
    put_json(out, &format!("[{}]", items.join(",")));
    ABI_OK
}

extern "C" fn cfg_subscribe(
    ctx: *mut c_void,
    module: *const c_char,
    key: *const c_char,
    user_ctx: *mut c_void,
    callback: Option<ChangeCb>,
    out_token: *mut u64,
) -> c_int {
    if out_token.is_null() {
        return ABI_ERR_CONFIG_INVALID;
    }
    let (binding, host) = unsafe { host_of(ctx) };
    let caller = caller_of(binding);
    let target = match unsafe { opt_str(module) } {
        Ok(Some(m)) => m,
        Ok(None) => caller.clone(),
        Err(e) => return e,
    };
    let key = match unsafe { opt_str(key) } {
        Ok(k) => k,
        Err(e) => return e,
    };
    if target != caller {
        if let Some(k) = &key {
            let Some(entry) = host
                .entries
                .iter()
                .find(|e| e.module == target && e.key == *k)
            else {
                return ABI_ERR_CONFIG_NOT_FOUND;
            };
            if entry.vis != Vis::PublicRead {
                return ABI_ERR_CONFIG_FORBIDDEN;
            }
        }
    } else if let Some(k) = &key {
        if !host
            .entries
            .iter()
            .any(|e| e.module == target && e.key == *k)
        {
            return ABI_ERR_CONFIG_NOT_FOUND;
        }
    }
    let Some(cb) = callback else {
        return ABI_ERR_CONFIG_INVALID;
    };
    host.next_token += 1;
    let token = host.next_token;
    host.subs.push(Sub {
        owner: caller,
        module: target,
        key,
        user_ctx: user_ctx as usize,
        cb,
        token,
    });
    unsafe { *out_token = token };
    ABI_OK
}

extern "C" fn cfg_unsubscribe(ctx: *mut c_void, token: u64) -> c_int {
    let (binding, host) = unsafe { host_of(ctx) };
    let caller = caller_of(binding);
    let Some(pos) = host.subs.iter().position(|s| s.token == token) else {
        return ABI_ERR_CONFIG_BAD_TOKEN;
    };
    if host.subs[pos].owner != caller {
        return ABI_ERR_CONFIG_BAD_TOKEN;
    }
    host.subs.remove(pos);
    ABI_OK
}

extern "C" fn cfg_free_buf(buf: ByteBuf) {
    if !buf.ptr.is_null() {
        unsafe { drop(Vec::from_raw_parts(buf.ptr, buf.len, buf.len)) };
    }
}

extern "C" fn record(user: *mut c_void, change: *const c_char) -> c_int {
    let log = unsafe { &mut *(user as *mut Vec<String>) };
    log.push(
        unsafe { CStr::from_ptr(change) }
            .to_str()
            .unwrap_or("")
            .to_string(),
    );
    0
}

fn deliver(host: &mut Host, module: &str, key: &str) {
    let Some(entry) = host
        .entries
        .iter()
        .find(|e| e.module == module && e.key == key)
    else {
        return;
    };
    let vis = entry.vis;
    let payload = format!(
        r#"{{"module":"{module}","key":"{key}","value":{}}}"#,
        entry.value
    );
    let targets: Vec<(ChangeCb, usize)> = host
        .subs
        .iter()
        .filter(|s| s.module == module)
        .filter(|s| s.key.as_deref().map_or(true, |k| k == key))
        .filter(|s| s.owner == module || vis == Vis::PublicRead)
        .map(|s| (s.cb, s.user_ctx))
        .collect();
    let change = CString::new(payload).expect("change json");
    for (cb, user_ctx) in targets {
        cb(user_ctx as *mut c_void, change.as_ptr());
    }
}

fn mock_host() -> Host {
    Host {
        entries: vec![
            Entry {
                module: "download",
                key: "multi_segment.enabled",
                value: "true".to_string(),
                vis: Vis::Owner,
            },
            Entry {
                module: "download",
                key: "wifi_only",
                value: "false".to_string(),
                vis: Vis::Owner,
            },
            Entry {
                module: "network",
                key: "proxy_url",
                value: r#""socks5://127.0.0.1:1080""#.to_string(),
                vis: Vis::PublicRead,
            },
            Entry {
                module: "perf",
                key: "profiles",
                value: "[]".to_string(),
                vis: Vis::Owner,
            },
            Entry {
                module: "perf",
                key: "public_metric",
                value: "1".to_string(),
                vis: Vis::PublicRead,
            },
            Entry {
                module: "webdav",
                key: "password",
                value: r#""hunter2""#.to_string(),
                vis: Vis::Secret,
            },
        ],
        subs: Vec::new(),
        next_token: 0,
    }
}

fn mock_vtable(bound: &Bound) -> GStoreConfigApiV1 {
    GStoreConfigApiV1 {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        struct_size: std::mem::size_of::<GStoreConfigApiV1>() as u32,
        capabilities: CONFIG_CAP_ALL,
        context: ctx_ptr(bound),
        get: Some(cfg_get),
        set: Some(cfg_set),
        list: Some(cfg_list),
        subscribe: Some(cfg_subscribe),
        unsubscribe: Some(cfg_unsubscribe),
        free_buf: Some(cfg_free_buf),
    }
}

fn read_json(vt: &GStoreConfigApiV1, module: Option<&CString>, key: &str) -> (c_int, String) {
    let get = vt.get.expect("get slot");
    let ckey = CString::new(key).expect("key");
    let module = module.map_or(null(), |m| m.as_ptr());
    let mut buf = ByteBuf {
        ptr: null_mut(),
        len: 0,
    };
    let rc = get(vt.context, module, ckey.as_ptr(), &mut buf);
    let json = if buf.ptr.is_null() {
        String::new()
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(buf.ptr, buf.len) };
        let s = String::from_utf8(bytes.to_vec()).expect("utf8 json");
        vt.free_buf.expect("free_buf slot")(buf);
        s
    };
    (rc, json)
}

#[test]
fn v5_vtable_roundtrips_get_set_list_subscribe_with_visibility() {
    let mut bound = bind("download", mock_host());
    let vt = mock_vtable(&bound);

    assert!(vt.has_capability(CONFIG_CAP_GET));
    assert!(vt.has_capability(CONFIG_CAP_SET));
    assert!(vt.has_capability(CONFIG_CAP_LIST));
    assert!(vt.has_capability(CONFIG_CAP_SUBSCRIBE));

    // own read
    let (rc, json) = read_json(&vt, None, "multi_segment.enabled");
    assert_eq!(rc, ABI_OK);
    assert_eq!(json, "true");

    // cross-module PublicRead read
    let network = CString::new("network").unwrap();
    let (rc, json) = read_json(&vt, Some(&network), "proxy_url");
    assert_eq!(rc, ABI_OK);
    assert_eq!(json, r#""socks5://127.0.0.1:1080""#);

    // cross-module Owner / Secret reads are typed errors
    let perf = CString::new("perf").unwrap();
    let webdav = CString::new("webdav").unwrap();
    assert_eq!(
        read_json(&vt, Some(&perf), "profiles").0,
        ABI_ERR_CONFIG_FORBIDDEN
    );
    assert_eq!(
        read_json(&vt, Some(&webdav), "password").0,
        ABI_ERR_CONFIG_FORBIDDEN
    );
    assert_eq!(read_json(&vt, None, "missing").0, ABI_ERR_CONFIG_NOT_FOUND);

    // own-module set only; the signature has no module argument at all.
    let set = vt.set.expect("set slot");
    let key = CString::new("wifi_only").unwrap();
    let val = CString::new("true").unwrap();
    assert_eq!(set(vt.context, key.as_ptr(), val.as_ptr()), ABI_OK);
    let (_, json) = read_json(&vt, None, "wifi_only");
    assert_eq!(json, "true");

    // list: own module has both entries; a foreign module only PublicRead.
    let list = vt.list.expect("list slot");
    let mut buf = ByteBuf {
        ptr: null_mut(),
        len: 0,
    };
    assert_eq!(list(vt.context, null(), &mut buf), ABI_OK);
    let own: serde_json::Value = serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(buf.ptr, buf.len)
    })
    .unwrap();
    vt.free_buf.unwrap()(buf);
    assert_eq!(own.as_array().unwrap().len(), 2);

    let mut buf = ByteBuf {
        ptr: null_mut(),
        len: 0,
    };
    assert_eq!(list(vt.context, perf.as_ptr(), &mut buf), ABI_OK);
    let foreign: serde_json::Value = serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(buf.ptr, buf.len)
    })
    .unwrap();
    vt.free_buf.unwrap()(buf);
    let foreign = foreign.as_array().unwrap();
    assert_eq!(foreign.len(), 1);
    assert_eq!(foreign[0]["key"], "public_metric");

    // subscriptions: own exact, own whole, foreign whole (key = NULL).
    let mut exact_log: Box<Vec<String>> = Box::new(Vec::new());
    let mut whole_log: Box<Vec<String>> = Box::new(Vec::new());
    let mut foreign_log: Box<Vec<String>> = Box::new(Vec::new());
    let subscribe = vt.subscribe.expect("subscribe slot");
    let mut exact_token = 0u64;
    let mut whole_token = 0u64;
    let mut foreign_token = 0u64;

    let hot = CString::new("multi_segment.enabled").unwrap();
    assert_eq!(
        subscribe(
            vt.context,
            null(),
            hot.as_ptr(),
            &mut *exact_log as *mut Vec<String> as *mut c_void,
            Some(record),
            &mut exact_token,
        ),
        ABI_OK
    );
    assert_eq!(
        subscribe(
            vt.context,
            null(),
            null(),
            &mut *whole_log as *mut Vec<String> as *mut c_void,
            Some(record),
            &mut whole_token,
        ),
        ABI_OK
    );
    assert_eq!(
        subscribe(
            vt.context,
            perf.as_ptr(),
            null(),
            &mut *foreign_log as *mut Vec<String> as *mut c_void,
            Some(record),
            &mut foreign_token,
        ),
        ABI_OK,
        "foreign whole-module subscription registers but grants nothing blanket"
    );

    // explicit foreign Owner/Secret subscription is a typed error.
    let profiles = CString::new("profiles").unwrap();
    assert_eq!(
        subscribe(
            vt.context,
            perf.as_ptr(),
            profiles.as_ptr(),
            &mut *foreign_log as *mut Vec<String> as *mut c_void,
            Some(record),
            &mut whole_token,
        ),
        ABI_ERR_CONFIG_FORBIDDEN
    );

    deliver(bound.host.as_mut(), "download", "multi_segment.enabled");
    assert_eq!(exact_log.len(), 1, "exact-key subscriber fires");
    assert_eq!(whole_log.len(), 1, "own whole-module subscriber fires");

    // A later Owner key in the foreign module must NOT reach key=NULL subscriber.
    deliver(bound.host.as_mut(), "perf", "profiles");
    assert_eq!(foreign_log.len(), 0, "key=NULL foreign sub must not receive Owner");
    // A PublicRead key in that same module does reach it.
    deliver(bound.host.as_mut(), "perf", "public_metric");
    assert_eq!(foreign_log.len(), 1, "PublicRead change is delivered");

    // Token ownership: another module cannot unsubscribe download's token.
    let other_name = CString::new("theme").unwrap();
    let other_ctx = GStoreConfigContextV1 {
        module_id: 2,
        module_name: other_name.as_ptr(),
        host: (&mut *bound.host as *mut Host).cast(),
    };
    let unsubscribe = vt.unsubscribe.expect("unsubscribe slot");
    assert_eq!(
        unsubscribe(
            (&other_ctx as *const GStoreConfigContextV1).cast_mut().cast(),
            exact_token
        ),
        ABI_ERR_CONFIG_BAD_TOKEN
    );
    assert_eq!(unsubscribe(vt.context, exact_token), ABI_OK);
    assert_eq!(unsubscribe(vt.context, whole_token), ABI_OK);
    assert_eq!(unsubscribe(vt.context, foreign_token), ABI_OK);

    deliver(bound.host.as_mut(), "download", "multi_segment.enabled");
    assert_eq!(exact_log.len(), 1, "unsubscribed subscriber must not fire");
    assert_eq!(whole_log.len(), 1, "unsubscribed subscriber must not fire");

    println!(
        "[manual-qa] v5 vtable round-trip: get/set/list/subscribe OK; cross-module Owner/Secret=FORBIDDEN({}); bad token={}; config struct_size={} CONFIG_CAP_ALL={:#x}",
        ABI_ERR_CONFIG_FORBIDDEN,
        ABI_ERR_CONFIG_BAD_TOKEN,
        std::mem::size_of::<GStoreConfigApiV1>(),
        CONFIG_CAP_ALL
    );
}
