// DlModuleAdapter：多 .so 场景下把 C ABI 模块包装为 GStoreModule trait（架构文档 4.3）
//
// 宿主 dlopen 模块 .so → dlsym register 符号 → 握手（传 Entry 收 Api）→
// 本适配器把 Api 函数指针转发为 trait 方法。持有 Library 保持 .so 驻留
// （架构 5.5：mount-once 永不 unload）。

use std::any::Any;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use gstore_contract::abi::{
    host_abi_satisfies, ByteBuf, GStoreConfigApiV1, GStoreConfigContextV1, ABI_ERR_CONFIG_BAD_TOKEN,
    ABI_ERR_CONFIG_FORBIDDEN, ABI_ERR_CONFIG_INVALID, ABI_ERR_CONFIG_NOT_FOUND, ABI_ERR_DETAIL,
    ABI_OK, CONFIG_CAP_ALL, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
    MIN_HOST_ABI,
};
use gstore_contract::error::ModuleError;
use gstore_core::config::{
    schema, secrets, ConfigBus, ConfigCaller, ConfigChangePayload, ConfigFilter, ConfigKey,
    ConfigSource, ConfigToken, ConfigVisibility,
};
use serde_json::Value;

use crate::manager::GStoreModule;

/// C ABI 函数指针类型（与 gstore_contract::abi 一致：安全 extern "C" fn）
type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type CreateFn = extern "C" fn(*const u8, usize, *mut u64) -> c_int;
type CallFn = extern "C" fn(
    u64,
    *const c_char,
    *const u8,
    usize,
    *mut *mut u8,
    *mut usize,
) -> c_int;
type CancelFn = extern "C" fn(u64, *const c_char) -> c_int;
type OnEventFn = extern "C" fn(u64, *const c_char, *const u8, usize) -> c_int;
type DestroyFn = extern "C" fn(u64) -> c_int;
type ShutdownFn = extern "C" fn() -> c_int;
type AllocFn = extern "C" fn(usize) -> *mut c_void;
type FreeFn = extern "C" fn(*mut c_void);

/// socket 保护实现签名（与 ABI v3 `GStoreModuleEntry::protect_fd` 一致）。
pub type SocketProtectFn = extern "C" fn(fd: c_int) -> c_int;

/// 默认 stub：Todo 4 接入 JNI `VpnService.protect` 之前的占位实现。
/// 返回 0 = 无需保护（宿主未运行 VPN 隧道），模块据此放行出站 socket。
extern "C" fn socket_protect_stub(_fd: c_int) -> c_int {
    0
}

/// 可替换的 socket 保护实现（ABI v3 的宿主侧 seam）。
///
/// 只在此处读写：Todo 4 在 Kotlin `ProxyVpnService` 持有 JNI 全局引用后，
/// 经 [`set_socket_protector`] 换成真实 `VpnService.protect(fd)`；在此之前
/// 保持 [`socket_protect_stub`]。每次 socket 创建读取一次，换实现仅在初始化期。
static SOCKET_PROTECT: std::sync::RwLock<SocketProtectFn> =
    std::sync::RwLock::new(socket_protect_stub);

/// 安装/替换 socket 保护实现（Todo 4 JNI 接线点；测试亦用于注入假实现）。
pub(crate) fn set_socket_protector(f: SocketProtectFn) {
    *SOCKET_PROTECT.write().unwrap_or_else(|e| e.into_inner()) = f;
}

/// 当前 socket 保护实现（测试断言替换是否生效）。
#[cfg(test)]
fn current_socket_protector() -> SocketProtectFn {
    *SOCKET_PROTECT.read().unwrap_or_else(|e| e.into_inner())
}

/// ABI v3 `protect_fd` 导出：委托给当前可替换实现。
extern "C" fn host_protect_fd(fd: c_int) -> c_int {
    SOCKET_PROTECT.read().unwrap_or_else(|e| e.into_inner())(fd)
}

// ---------------------------------------------------------------------------
// ABI v5 module configuration (Todo 11 / C7 / C18)
// ---------------------------------------------------------------------------

type ChangeCallback = extern "C" fn(user_ctx: *mut c_void, change_json: *const c_char) -> c_int;

/// Per-module lifetime gate shared by the vtable context and delivery pump.
///
/// The vtable context, its binding handle, and this binding are intentionally
/// leaked for the process lifetime (mount-once: a `.so` is never `dlclose`d).
/// That makes the raw pointers handed to module code permanently valid even
/// after a logical unload, so a late callback can only observe `unloaded=true`
/// instead of dereferencing freed memory.
pub(crate) struct ModuleConfigBinding {
    module_id: u64,
    module_name: String,
    generation: AtomicU64,
    state: Mutex<BindingState>,
    /// Process-lifetime keepalive for the module's dlopen handle.
    ///
    /// A callback snapshotted just before `detach()` may still be executing
    /// inside the `.so`. The binding itself is leaked for the process lifetime,
    /// so holding the `Arc<Library>` here makes "mount-once: never dlclose"
    /// true even when a discarded adapter's `_lib` field drops. Never cleared
    /// by `detach`/`Drop`.
    library: Mutex<Option<Box<dyn Any + Send + Sync>>>,
}

struct BindingState {
    unloaded: bool,
    active_deliveries: usize,
    pending_shutdown: Option<Arc<dyn GStoreModule>>,
}

struct BindingHandle {
    binding: Arc<ModuleConfigBinding>,
}

impl ModuleConfigBinding {
    fn new(module_id: u64, module_name: impl Into<String>) -> Arc<Self> {
        Arc::new(Self {
            module_id,
            module_name: module_name.into(),
            generation: AtomicU64::new(1),
            state: Mutex::new(BindingState {
                unloaded: false,
                active_deliveries: 0,
                pending_shutdown: None,
            }),
            library: Mutex::new(None),
        })
    }

    /// Pins the dlopen handle so it outlives every possible callback frame.
    pub(crate) fn keep_library<T>(self: &Arc<Self>, library: T)
    where
        T: Any + Send + Sync,
    {
        let mut slot = self
            .library
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if slot.is_none() {
            *slot = Some(Box::new(library));
        }
    }

    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    fn is_unloaded(&self) -> bool {
        lock_state(&self.state).unloaded
    }

    /// Enters a delivery only while loaded and on the generation the
    /// subscription was registered for. The returned guard keeps unload's
    /// deferred shutdown from running until the callback returns.
    fn begin_delivery(self: &Arc<Self>, generation: u64) -> Option<DeliveryGuard> {
        let mut state = lock_state(&self.state);
        if state.unloaded || generation != self.generation() {
            return None;
        }
        state.active_deliveries += 1;
        Some(DeliveryGuard {
            binding: Arc::clone(self),
        })
    }

    /// Idempotently revokes this binding without calling `shutdown`.
    ///
    /// Used by `Drop for DlModuleAdapter` (the `.so` is about to be `dlclose`d,
    /// so every subscription must be gone before the library handle drops) and
    /// by post-register failure cleanup. `shutdown` is deliberately not called:
    /// it may already have run, and Drop must never re-enter module code.
    pub(crate) fn detach(self: &Arc<Self>) {
        let bumped = {
            let mut state = lock_state(&self.state);
            if state.unloaded {
                false
            } else {
                state.unloaded = true;
                true
            }
        };
        if bumped {
            self.generation.fetch_add(1, Ordering::AcqRel);
        }
        clear_subscriptions_for_binding(self);
    }

    /// Marks the module unloaded, clears its subscriptions, and shuts the
    /// module down now or after the last in-flight callback returns.
    pub(crate) fn begin_unload(self: &Arc<Self>, module: Arc<dyn GStoreModule>) {
        let immediate = {
            let mut state = lock_state(&self.state);
            if state.unloaded {
                None
            } else {
                state.unloaded = true;
                self.generation.fetch_add(1, Ordering::AcqRel);
                if state.active_deliveries == 0 {
                    Some(module)
                } else {
                    state.pending_shutdown = Some(module);
                    None
                }
            }
        };
        clear_subscriptions_for_binding(self);
        if let Some(module) = immediate {
            module.shutdown();
        }
    }
}

struct DeliveryGuard {
    binding: Arc<ModuleConfigBinding>,
}

impl Drop for DeliveryGuard {
    fn drop(&mut self) {
        let pending = {
            let mut state = lock_state(&self.binding.state);
            state.active_deliveries = state.active_deliveries.saturating_sub(1);
            if state.active_deliveries == 0 && state.unloaded {
                state.pending_shutdown.take()
            } else {
                None
            }
        };
        if let Some(module) = pending {
            module.shutdown();
        }
    }
}

fn lock_state(state: &Mutex<BindingState>) -> MutexGuard<'_, BindingState> {
    state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct ModuleSubscription {
    token: u64,
    generation: u64,
    target_module: String,
    key: Option<String>,
    user_ctx: usize,
    callback: ChangeCallback,
    binding: Arc<ModuleConfigBinding>,
}

#[derive(Default)]
struct SubscriptionRegistry {
    subscriptions: Vec<ModuleSubscription>,
    next_token: u64,
}

fn registry() -> &'static Mutex<SubscriptionRegistry> {
    static REGISTRY: OnceLock<Mutex<SubscriptionRegistry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(SubscriptionRegistry {
            subscriptions: Vec::new(),
            next_token: 1,
        })
    })
}

fn lock_registry() -> MutexGuard<'static, SubscriptionRegistry> {
    registry().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct PumpState {
    bus: Arc<ConfigBus>,
    tokens: Vec<ConfigToken>,
}

fn pump() -> &'static Mutex<Option<PumpState>> {
    static PUMP: OnceLock<Mutex<Option<PumpState>>> = OnceLock::new();
    PUMP.get_or_init(|| Mutex::new(None))
}

fn lock_pump() -> MutexGuard<'static, Option<PumpState>> {
    pump().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Registers (or re-registers) the host pump on the current config bus.
///
/// `ConfigBus` fans out only to subscriptions whose filter names the changed
/// module, so one `Host` subscription per registered namespace is required.
/// The pump holds no store or writer lock; the bus invokes callbacks after it
/// has committed and released its own snapshot lock.
fn ensure_pump() {
    let Some(bus) = crate::config_api::host_bus() else {
        return;
    };
    let mut current = lock_pump();
    if current
        .as_ref()
        .is_some_and(|state| Arc::ptr_eq(&state.bus, &bus))
    {
        return;
    }
    if let Some(previous) = current.take() {
        for token in previous.tokens {
            let _ = previous.bus.unsubscribe(&token);
        }
    }
    let mut modules: Vec<&'static str> = schema::entries()
        .iter()
        .map(|entry| entry.key.module())
        .collect();
    modules.sort_unstable();
    modules.dedup();
    let tokens = modules
        .into_iter()
        .map(|module| {
            bus.subscribe(
                ConfigCaller::Host,
                ConfigFilter::whole_module(module),
                deliver_change,
            )
        })
        .collect();
    *current = Some(PumpState { bus, tokens });
}

fn clear_pump() {
    let mut current = lock_pump();
    if let Some(state) = current.take() {
        for token in state.tokens {
            let _ = state.bus.unsubscribe(&token);
        }
    }
}

fn authorized_foreign(entry: &gstore_core::config::ConfigEntry) -> bool {
    entry.visibility == ConfigVisibility::PublicRead
        && !secrets::is_secret_entry(entry)
}

/// Snapshot matching subscriptions, release the registry lock, then invoke.
///
/// The config writer lock is never held here: the store commits first, the bus
/// snapshots and releases, and this function keeps its own tiny snapshot.
fn deliver_change(payload: &ConfigChangePayload) {
    let Ok(key) = ConfigKey::new(payload.module.clone(), payload.key.clone()) else {
        return;
    };
    let Some(entry) = schema::entry(&key) else {
        return;
    };
    let foreign_ok = authorized_foreign(entry);
    let matching: Vec<ModuleSubscription> = {
        let registry = lock_registry();
        registry
            .subscriptions
            .iter()
            .filter(|subscription| {
                subscription.target_module == payload.module
                    && subscription
                        .key
                        .as_deref()
                        .is_none_or(|key| key == payload.key)
                    && (subscription.binding.module_name == payload.module || foreign_ok)
            })
            .map(|subscription| ModuleSubscription {
                token: subscription.token,
                generation: subscription.generation,
                target_module: subscription.target_module.clone(),
                key: subscription.key.clone(),
                user_ctx: subscription.user_ctx,
                callback: subscription.callback,
                binding: Arc::clone(&subscription.binding),
            })
            .collect()
    };
    let Ok(json) = serde_json::to_string(payload) else {
        return;
    };
    let Ok(change_json) = CString::new(json) else {
        return;
    };
    for subscription in matching {
        let Some(_guard) = subscription.binding.begin_delivery(subscription.generation) else {
            continue;
        };
        let code = (subscription.callback)(
            subscription.user_ctx as *mut c_void,
            change_json.as_ptr(),
        );
        if code != ABI_OK {
            crate::log_bridge::push_host_log(
                2,
                format!(
                    "config: module {} callback returned {code} for {}",
                    subscription.binding.module_name, key.wire()
                ),
            );
        }
    }
}

fn clear_subscriptions_for_binding(binding: &Arc<ModuleConfigBinding>) {
    let mut registry = lock_registry();
    registry.subscriptions.retain(|subscription| {
        !std::ptr::eq(
            Arc::as_ptr(&subscription.binding),
            Arc::as_ptr(binding),
        )
    });
}

/// Clears every native-module subscription and detaches the pump.
///
/// Called from `HostInspector::reset_bridges` (isolate teardown) and from
/// `config_api::install_core_config`. Loaded modules keep running, but their
/// subscriptions are bound to the previous bus/store: **modules must
/// resubscribe after a core re-init** (their next `subscribe` also re-installs
/// the pump on the new bus).
pub(crate) fn clear_module_config_sinks() {
    let bindings: Vec<Arc<ModuleConfigBinding>> = {
        let mut registry = lock_registry();
        registry
            .subscriptions
            .drain(..)
            .map(|subscription| subscription.binding)
            .collect()
    };
    for binding in bindings {
        binding.generation.fetch_add(1, Ordering::AcqRel);
    }
    clear_pump();
}

fn binding_from_ctx(ctx: *mut c_void) -> Option<Arc<ModuleConfigBinding>> {
    if ctx.is_null() {
        return None;
    }
    // SAFETY: `ctx` is the `context` field of a vtable built by
    // `build_config_vtable`, which leaks a `GStoreConfigContextV1` whose
    // `host` points at a leaked `BindingHandle`. Both outlive every module
    // callback (mount-once, never dlclosed), so the borrow is valid.
    let context = unsafe { &*(ctx as *const GStoreConfigContextV1) };
    if context.host.is_null() {
        return None;
    }
    // SAFETY: same invariant as above; `host` is the leaked BindingHandle.
    let handle = unsafe { &*(context.host as *const BindingHandle) };
    Some(Arc::clone(&handle.binding))
}

fn opt_string(ptr: *const c_char) -> Result<Option<String>, c_int> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: the ABI contract requires a NUL-terminated C string owned by the
    // caller for the duration of this call; we only read it here.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(|text| Some(text.to_string()))
        .map_err(|_| ABI_ERR_CONFIG_INVALID)
}

fn parse_key(module: &str, key: &str) -> Result<ConfigKey, c_int> {
    ConfigKey::new(module.to_string(), key.to_string()).map_err(|_| ABI_ERR_CONFIG_INVALID)
}

fn target_module(binding: &ModuleConfigBinding, module: Option<String>) -> String {
    module.unwrap_or_else(|| binding.module_name.clone())
}

fn put_json(out: *mut ByteBuf, json: &str) {
    if out.is_null() {
        return;
    }
    let bytes = json.as_bytes().to_vec().into_boxed_slice();
    let len = bytes.len();
    let ptr = Box::into_raw(bytes) as *mut u8;
    // SAFETY: `out` is a caller-provided out-parameter (checked non-null). The
    // buffer is heap-owned and released only by `config_free_buf`, which
    // reconstructs the exact `len == capacity` slice.
    unsafe { *out = ByteBuf { ptr, len } };
}

fn store_value(key: &ConfigKey) -> Result<Value, c_int> {
    let Some(store) = crate::config_api::installed_store_for_test() else {
        return Err(ABI_ERR_CONFIG_INVALID);
    };
    store.get(key).map_err(|_| ABI_ERR_CONFIG_INVALID)
}

extern "C" fn config_get(
    ctx: *mut c_void,
    module_or_null: *const c_char,
    key: *const c_char,
    out_json: *mut ByteBuf,
) -> c_int {
    let Some(binding) = binding_from_ctx(ctx) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    if out_json.is_null() || binding.is_unloaded() {
        return ABI_ERR_CONFIG_INVALID;
    }
    // SAFETY: `out_json` is non-null per the guard above; zero it so a failure
    // never leaves the caller with an uninitialised buffer.
    unsafe { *out_json = ByteBuf { ptr: std::ptr::null_mut(), len: 0 } };
    let key = match opt_string(key) {
        Ok(Some(key)) => key,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let module = match opt_string(module_or_null) {
        Ok(module) => target_module(&binding, module),
        Err(code) => return code,
    };
    let key = match parse_key(&module, &key) {
        Ok(key) => key,
        Err(code) => return code,
    };
    let Some(entry) = schema::entry(&key) else {
        return ABI_ERR_CONFIG_NOT_FOUND;
    };
    if module != binding.module_name && !authorized_foreign(entry) {
        return ABI_ERR_CONFIG_FORBIDDEN;
    }
    match store_value(&key) {
        Ok(value) => {
            let json = serde_json::to_string(&value).unwrap_or_else(|_| "null".to_string());
            put_json(out_json, &json);
            ABI_OK
        }
        Err(code) => code,
    }
}

extern "C" fn config_set(
    ctx: *mut c_void,
    key: *const c_char,
    value_json: *const c_char,
) -> c_int {
    let Some(binding) = binding_from_ctx(ctx) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    if binding.is_unloaded() {
        return ABI_ERR_CONFIG_INVALID;
    }
    let key = match opt_string(key) {
        Ok(Some(key)) => key,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let value = match opt_string(value_json) {
        Ok(Some(value)) => value,
        Ok(None) | Err(_) => return ABI_ERR_CONFIG_INVALID,
    };
    let key = match parse_key(&binding.module_name, &key) {
        Ok(key) => key,
        Err(code) => return code,
    };
    if schema::entry(&key).is_none() {
        return ABI_ERR_CONFIG_NOT_FOUND;
    }
    if serde_json::from_str::<Value>(&value).is_err() {
        return ABI_ERR_CONFIG_INVALID;
    }
    match crate::config_api::set(
        binding.module_name.clone(),
        key.key().to_string(),
        value,
        ConfigSource::Module.as_str().to_string(),
    ) {
        Ok(_) => ABI_OK,
        Err(error) => config_error_code(&error),
    }
}

fn config_error_code(error: &str) -> c_int {
    if error.contains("config_unknown_key") {
        ABI_ERR_CONFIG_NOT_FOUND
    } else if error.contains("config_not_permitted") {
        ABI_ERR_CONFIG_FORBIDDEN
    } else {
        ABI_ERR_CONFIG_INVALID
    }
}

extern "C" fn config_list(
    ctx: *mut c_void,
    module_or_null: *const c_char,
    out_json: *mut ByteBuf,
) -> c_int {
    let Some(binding) = binding_from_ctx(ctx) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    if out_json.is_null() || binding.is_unloaded() {
        return ABI_ERR_CONFIG_INVALID;
    }
    // SAFETY: non-null out-parameter; zeroed before any early return.
    unsafe { *out_json = ByteBuf { ptr: std::ptr::null_mut(), len: 0 } };
    let module = match opt_string(module_or_null) {
        Ok(module) => target_module(&binding, module),
        Err(code) => return code,
    };
    let own = module == binding.module_name;
    let mut items = Vec::new();
    for entry in schema::module_entries(&module) {
        if !own && !authorized_foreign(entry) {
            continue;
        }
        let key = &entry.key;
        let snapshot = crate::config_api::installed_store_for_test()
            .and_then(|store| store.snapshot(key).ok().flatten());
        let value = if own && entry.sensitive {
            match store_value(key) {
                Ok(value) => value,
                Err(code) => return code,
            }
        } else {
            snapshot
                .as_ref()
                .and_then(|snapshot| snapshot.value.clone())
                .unwrap_or_else(|| entry.default_json.clone())
        };
        items.push(serde_json::json!({
            "module": key.module(),
            "key": key.key(),
            "wireKey": key.wire(),
            "value": value,
            "revision": snapshot.as_ref().map(|snapshot| snapshot.revision).unwrap_or(0),
            "visibility": entry.visibility.as_str(),
        }));
    }
    match serde_json::to_string(&items) {
        Ok(json) => {
            put_json(out_json, &json);
            ABI_OK
        }
        Err(_) => ABI_ERR_CONFIG_INVALID,
    }
}

extern "C" fn config_subscribe(
    ctx: *mut c_void,
    module_or_null: *const c_char,
    key_or_null: *const c_char,
    user_ctx: *mut c_void,
    callback: Option<ChangeCallback>,
    out_token: *mut u64,
) -> c_int {
    let Some(binding) = binding_from_ctx(ctx) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    let Some(callback) = callback else {
        return ABI_ERR_CONFIG_INVALID;
    };
    if out_token.is_null() || binding.is_unloaded() {
        return ABI_ERR_CONFIG_INVALID;
    }
    let module = match opt_string(module_or_null) {
        Ok(module) => target_module(&binding, module),
        Err(code) => return code,
    };
    let key = match opt_string(key_or_null) {
        Ok(key) => key,
        Err(code) => return code,
    };
    if let Some(key_name) = &key {
        let key = match parse_key(&module, key_name) {
            Ok(key) => key,
            Err(code) => return code,
        };
        let Some(entry) = schema::entry(&key) else {
            return ABI_ERR_CONFIG_NOT_FOUND;
        };
        if module != binding.module_name && !authorized_foreign(entry) {
            return ABI_ERR_CONFIG_FORBIDDEN;
        }
    } else if module != binding.module_name {
        // A foreign whole-module subscription is accepted, but it is never a
        // blanket grant: `deliver_change` re-checks each change's visibility.
        if parse_key(&module, "probe").is_err() {
            return ABI_ERR_CONFIG_INVALID;
        }
    }
    let token = {
        let mut registry = lock_registry();
        let token = registry.next_token;
        registry.next_token += 1;
        registry.subscriptions.push(ModuleSubscription {
            token,
            generation: binding.generation(),
            target_module: module,
            key,
            user_ctx: user_ctx as usize,
            callback,
            binding: Arc::clone(&binding),
        });
        token
    };
    ensure_pump();
    // SAFETY: non-null out-parameter guarded above.
    unsafe { *out_token = token };
    ABI_OK
}

extern "C" fn config_unsubscribe(ctx: *mut c_void, token: u64) -> c_int {
    let Some(binding) = binding_from_ctx(ctx) else {
        return ABI_ERR_CONFIG_INVALID;
    };
    let mut registry = lock_registry();
    let Some(index) = registry
        .subscriptions
        .iter()
        .position(|subscription| subscription.token == token)
    else {
        return ABI_ERR_CONFIG_BAD_TOKEN;
    };
    if !std::ptr::eq(
        Arc::as_ptr(&registry.subscriptions[index].binding),
        Arc::as_ptr(&binding),
    ) {
        return ABI_ERR_CONFIG_BAD_TOKEN;
    }
    let subscription = registry.subscriptions.remove(index);
    if subscription.generation != binding.generation() {
        return ABI_ERR_CONFIG_BAD_TOKEN;
    }
    ABI_OK
}

extern "C" fn config_free_buf(buf: ByteBuf) {
    if buf.ptr.is_null() {
        return;
    }
    // SAFETY: every buffer handed out by `put_json` is a `Box<[u8]>` with
    // `len == capacity`, so rebuilding the same slice and dropping it is the
    // unique matching free. Module code must never free host buffers itself.
    unsafe { drop(Vec::from_raw_parts(buf.ptr, buf.len, buf.len)) };
}

fn detach_config_binding(binding: &Option<Arc<ModuleConfigBinding>>) {
    if let Some(binding) = binding {
        binding.detach();
    }
}

fn build_config_vtable(
    binding: &Arc<ModuleConfigBinding>,
) -> GStoreConfigApiV1 {
    let name = CString::new(binding.module_name.as_str()).unwrap_or_default();
    let name_ptr = name.into_raw();
    let handle = Box::into_raw(Box::new(BindingHandle {
        binding: Arc::clone(binding),
    }));
    let context = Box::into_raw(Box::new(GStoreConfigContextV1 {
        module_id: binding.module_id,
        module_name: name_ptr,
        host: handle.cast(),
    }));
    GStoreConfigApiV1 {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        struct_size: std::mem::size_of::<GStoreConfigApiV1>() as u32,
        capabilities: CONFIG_CAP_ALL,
        context: context.cast(),
        get: Some(config_get),
        set: Some(config_set),
        list: Some(config_list),
        subscribe: Some(config_subscribe),
        unsubscribe: Some(config_unsubscribe),
        free_buf: Some(config_free_buf),
    }
}

/// Builds the host injection table for one module.
///
/// `config` is the module's already-built vtable (or null for ABI < 5).
fn host_entry_with_config(
    abi: u32,
    config: *const GStoreConfigApiV1,
) -> Result<GStoreModuleEntry, String> {
    if !(MIN_HOST_ABI..=GSTORE_MODULE_ABI_VERSION).contains(&abi) {
        return Err(format!(
            "unsupported module ABI {abi} (host supports {MIN_HOST_ABI}..={GSTORE_MODULE_ABI_VERSION})"
        ));
    }
    let entry_size = match abi {
        3 => GStoreModuleEntry::PLATFORM_OFFSET,
        4 => GStoreModuleEntry::CONFIG_OFFSET,
        _ => std::mem::size_of::<GStoreModuleEntry>(),
    } as u32;
    let config = if abi >= 5 { config } else { std::ptr::null() };
    Ok(GStoreModuleEntry {
        abi_version: abi,
        entry_size,
        log: Some(crate::log_bridge::host_log),
        alloc: None,
        free: None,
        emit_event: Some(crate::event_bridge::host_emit_event),
        context: std::ptr::null_mut(),
        // ABI v3：代理域模块经此槽安装一个 SocketProtector 覆盖全部出站 socket。
        protect_fd: Some(host_protect_fd),
        // ABI v4：真实 platform vtable 接线不属于本 todo，保持 NULL。
        platform: std::ptr::null(),
        config,
    })
}

/// 构造宿主注入表（`load` 与测试共用）。
///
/// `abi` 是模块探测到的目标 ABI（`gstore_mod_<name>_abi`，缺失时回退 3）。
/// **必须逐版精确**，绝不把 v5 的 `entry_size` 报给旧模块：
/// - `abi == 3` → `PLATFORM_OFFSET`（v3 布局，无 `platform`/`config` 槽）；
/// - `abi == 4` → `CONFIG_OFFSET`（v4 布局，有 `platform`、无 `config`）；
/// - `abi == 5` → `size_of::<GStoreModuleEntry>()`（v5 布局，有 `config`）。
///
/// 越界 ABI 拒绝，绝不静默降级。此无模块身份的重载不注入 config 槽（测试用）；
/// 生产路径走 [`host_entry_with_config`], 每模块一份 vtable。
#[cfg(test)]
fn host_entry(abi: u32) -> Result<GStoreModuleEntry, String> {
    host_entry_with_config(abi, std::ptr::null())
}

fn api_name(api: &GStoreModuleApi) -> Result<String, String> {
    if api.name.is_null() {
        return Err("module api.name is null".to_string());
    }
    Ok(unsafe { CStr::from_ptr(api.name) }.to_string_lossy().into_owned())
}

/// 握手校验（构造 Entry → 调用模块 register → 校验返回码/name/ABI/必填函数）。
/// 抽成独立函数以便测试在不 dlopen 的情况下注入合成 register。
///
/// `abi` 是模块探测到的目标 ABI（`gstore_mod_<name>_abi`，缺失时回退 3）；
/// 只允许一个 gate：`min_host_abi > GSTORE_MODULE_ABI_VERSION` 拒绝。
/// 这是追加式 ABI 演进的关键——不做任何精确匹配，旧模块（min_host_abi <= 2）
/// 因此仍能挂载到 v3 宿主。
#[cfg(test)]
fn handshake_with(
    register: RegisterFn,
    module_name: &str,
    abi: u32,
) -> Result<(String, GStoreModuleApi), String> {
    handshake_with_config(register, module_name, abi, std::ptr::null())
}

fn handshake_with_config(
    register: RegisterFn,
    module_name: &str,
    abi: u32,
    config: *const GStoreConfigApiV1,
) -> Result<(String, GStoreModuleApi), String> {
    let entry = host_entry_with_config(abi, config)?;
    let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = unsafe { register(&entry, api.as_mut_ptr()) };
    let api = unsafe { api.assume_init() };
    if code != 0 {
        return Err(format!("module rejected handshake: code={code}"));
    }
    let name = api_name(&api)?;
    if name != module_name {
        return Err(format!(
            "module name mismatch: file says {module_name}, api says {name}"
        ));
    }
    if !host_abi_satisfies(api.min_host_abi, GSTORE_MODULE_ABI_VERSION) {
        return Err(format!(
            "module {name} requires host ABI >= {} but host is {}",
            api.min_host_abi, GSTORE_MODULE_ABI_VERSION
        ));
    }
    api.create.ok_or("module missing create")?;
    api.call.ok_or("module missing call")?;
    api.destroy.ok_or("module missing destroy")?;
    api.free.ok_or("module missing free")?;
    Ok((name, api))
}

pub struct DlModuleAdapter {
    #[cfg(unix)]
    _lib: Arc<libloading::os::unix::Library>, // 保持 .so 加载（永不 unload）
    #[cfg(not(unix))]
    _lib: Arc<libloading::Library>, // 保持 .so 加载（永不 unload）
    name: &'static str,             // load 时泄漏一次（模块生命周期内固定）
    version: u32,
    create: CreateFn,
    call: CallFn,
    cancel: Option<CancelFn>,
    on_event: Option<OnEventFn>,
    destroy: DestroyFn,
    shutdown: Option<ShutdownFn>,
    free: FreeFn, // 释放模块分配的内存（谁分配谁释放）
    config_binding: Option<Arc<ModuleConfigBinding>>,
}

/// Derives the module name from a `.so` path (same convention as `load`).
pub(crate) fn module_name_from_so_path(path: &std::path::Path) -> Result<String, String> {
    let file_name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("invalid .so filename")?;
    parse_module_name(file_name)
}

/// 从 .so 文件名推导模块名：libgstore_mod_qr.so → qr；
/// 版本化文件（libgstore_mod_qr_0.2.0.so）同样剥离版本后缀 → qr。
fn parse_module_name(file_name: &str) -> Result<String, String> {
    let stem = file_name
        .strip_prefix("lib")
        .and_then(|s| s.strip_suffix(".so"))
        .unwrap_or(file_name);
    let with_version = stem.strip_prefix("gstore_mod_").unwrap_or(stem);
    // 先剥版本号，再剥 GPU 变体后缀（两者可叠加）
    let name = strip_variant_suffix(strip_version_suffix(with_version));
    if name.is_empty() {
        return Err(format!("cannot derive module name from {file_name}"));
    }
    Ok(name.to_string())
}

/// 剥离尾部 GPU 变体后缀（`_cpu` / `_opencl` / `_vulkan`）。
///
/// 变体 .so（如 `libgstore_mod_llm_opencl.so`）与主模块同名 → `llm`，
/// 这样宿主才能按同一模块名加载不同后端（调用方按优先级尝试，谁先成功用谁）。
fn strip_variant_suffix(s: &str) -> &str {
    for tag in ["_opencl", "_vulkan", "_cpu"] {
        if let Some(stripped) = s.strip_suffix(tag) {
            if !stripped.is_empty() {
                return stripped;
            }
        }
    }
    s
}

/// 剥离尾部形如 `_1.2.3` 的版本后缀（要求全为数字段，至少含一个点）
fn strip_version_suffix(s: &str) -> &str {
    if let Some(idx) = s.rfind('_') {
        let tail = &s[idx + 1..];
        if tail.contains('.')
            && tail
                .split('.')
                .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
        {
            return &s[..idx];
        }
    }
    s
}

impl DlModuleAdapter {
    /// dlopen + 握手，构造适配器
/// 尽力预加载 OpenCL 运行库（RTLD_GLOBAL）。
///
/// OpenCL 版 llm 模块（ggml-opencl）引用一组 `cl*` 未定义符号，而 NEEDED 里没有
/// libOpenCL.so（Android NDK 不提供），因此必须在 dlopen 该模块之前，让设备上的
/// libOpenCL 进入**全局符号组**；否则模块会因符号无法解析而加载失败。
/// 找不到时静默跳过（CPU 构建完全不受影响）。
fn preload_opencl() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        const CANDIDATES: [&str; 5] = [
            "libOpenCL.so",
            "libOpenCL.so.1",
            "/vendor/lib64/libOpenCL.so",
            "/system/lib64/libOpenCL.so",
            "/vendor/lib/libOpenCL.so",
        ];
        for path in CANDIDATES {
            // 句柄故意泄漏：整个进程生命周期保持加载，供后续 dlopen 解析符号
            let loaded = unsafe {
                libloading::os::unix::Library::open(
                    Some(path),
                    libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_GLOBAL,
                )
            }
            .map(|lib| {
                std::mem::forget(lib);
                true
            })
            .unwrap_or(false);
            if loaded {
                crate::log_bridge::push_host_log(1, format!("gstore_host: 已预加载 OpenCL - {path}"));
                return;
            }
        }
        crate::log_bridge::push_host_log(
            0,
            "gstore_host: 未找到 libOpenCL（OpenCL 版 llm 模块将加载失败并回退）".to_string(),
        );
    });
}

    #[cfg(test)]
    pub fn load(path: &std::path::Path) -> Result<Self, String> {
        Self::load_with_module_id(path, 0)
    }

    /// dlopen + handshake with the manager-assigned `module_id` bound into the
    /// ABI v5 config context (the context's identity is host-authoritative).
    pub(crate) fn load_with_module_id(
        path: &std::path::Path,
        module_id: u64,
    ) -> Result<Self, String> {
        Self::preload_opencl();
        // 1. dlopen
        // 用 RTLD_NOW 强制立即绑定全部符号：libloading::Library::new 默认 RTLD_LAZY，
        // 在 Android 16 (16KB page) 上对提取到 files/ 目录的 .so 懒绑定解析异常，
        // GOT 表项停留在链接时虚拟地址（未加加载基址），首次 PLT 调用（如 memcpy）
        // 跳到未映射地址 SIGSEGV（真机崩溃根因）。RTLD_NOW 与 .so 内 BIND_NOW 一致。
        #[cfg(unix)]
        let lib = Arc::new(
            unsafe {
                libloading::os::unix::Library::open(
                    Some(path),
                    libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_LOCAL,
                )
            }
            .map_err(|e| format!("dlopen {}: {e}", path.display()))?,
        );
        #[cfg(not(unix))]
        let lib = Arc::new(
            unsafe { libloading::Library::new(path) }
                .map_err(|e| format!("dlopen {}: {e}", path.display()))?,
        );

        // 2. 按模块名约定解析 register 符号：gstore_mod_<name>_register
        //    模块名从 .so 文件名推导（libgstore_mod_qr.so → qr）。
        let file_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("invalid .so filename")?;
        let module_name = parse_module_name(file_name)?;
        let register_sym = format!("gstore_mod_{module_name}_register\0");

        // 3. dlsym register 入口（模块按名约定）
        let register: libloading::os::unix::Symbol<RegisterFn> = unsafe {
            lib.get(register_sym.as_bytes())
        }
        .map_err(|e| format!("no register symbol {} in {}: {e}", register_sym.trim_end_matches('\0'), path.display()))?;

        // 3b. 可选 ABI 探测：gstore_mod_<name>_abi 返回模块构建时的 ABI 版本。
        //     缺失 = pre-v4 模块（构建于 ABI 3），回退 3（v3 宿主 entry）。
        let probe_sym = format!("gstore_mod_{module_name}_abi\0");
        let probe_abi: u32 = match unsafe { lib.get::<extern "C" fn() -> u32>(probe_sym.as_bytes()) }
        {
            Ok(probe) => probe(),
            Err(_) => 3,
        };
        crate::log_bridge::push_host_log(
            1,
            format!("gstore_host: module={module_name} probe_abi={probe_abi}"),
        );

        // 3c. ABI v5：为每个模块构造独立 config vtable + 宿主绑定的 context。
        //     指针故意泄漏（mount-once，模块可能在进程内一直持有）。
        let (config_binding, config_ptr) = if probe_abi >= 5 {
            let binding = ModuleConfigBinding::new(module_id, module_name.clone());
            // Pin the library before register can subscribe, so every later
            // error/discard path keeps the code mapped for in-flight callbacks.
            binding.keep_library(Arc::clone(&lib));
            let vtable = Box::into_raw(Box::new(build_config_vtable(&binding)));
            (Some(binding), vtable.cast_const())
        } else {
            (None, std::ptr::null())
        };

        // 3d. 握手：传 Entry（宿主服务）收 Api（模块能力）+ ABI/名字校验。
        //     `register` may already have subscribed through the vtable, so any
        //     failure from here on must detach before `lib` is dlclose'd.
        let (name, api) =
            match handshake_with_config(*register, &module_name, probe_abi, config_ptr) {
                Ok(handshake) => handshake,
                Err(error) => {
                    detach_config_binding(&config_binding);
                    return Err(error);
                }
            };

        // 4. 包装
        let Some(create) = api.create else {
            detach_config_binding(&config_binding);
            return Err("module missing create".to_string());
        };
        let Some(call) = api.call else {
            detach_config_binding(&config_binding);
            return Err("module missing call".to_string());
        };
        let Some(destroy) = api.destroy else {
            detach_config_binding(&config_binding);
            return Err("module missing destroy".to_string());
        };
        let Some(free) = api.free else {
            detach_config_binding(&config_binding);
            return Err("module missing free".to_string());
        };

        Ok(Self {
            _lib: lib,
            name: Box::leak(name.into_boxed_str()),
            version: api.version,
            create,
            call,
            cancel: api.cancel,
            on_event: api.on_event,
            destroy,
            shutdown: api.shutdown,
            free,
            config_binding,
        })
    }

    /// 把模块分配的内存拷贝进 Vec 并用模块 free 释放（谁分配谁释放）
    unsafe fn copy_out(&self, ptr: *mut u8, len: usize) -> Vec<u8> {
        let bytes = if len == 0 || ptr.is_null() {
            Vec::new()
        } else {
            std::slice::from_raw_parts(ptr, len).to_vec()
        };
        (self.free)(ptr as *mut c_void);
        bytes
    }

    /// 请求模块取消某次在途调用（ABI `cancel` 槽；模块未实现则无操作）
    fn cancel_call(&self, instance: u64, request_id: &str) -> Result<(), ModuleError> {
        let Some(cancel) = self.cancel else {
            return Ok(());
        };
        let c_req = CString::new(request_id)
            .map_err(|_| ModuleError::invalid_arg("request_id contains NUL"))?;
        let code = unsafe { cancel(instance, c_req.as_ptr()) };
        if code == ABI_OK {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module cancel failed: code={code}")))
        }
    }
}

impl GStoreModule for DlModuleAdapter {
    fn name(&self) -> &'static str {
        self.name
    }

    fn version(&self) -> u32 {
        self.version
    }

    fn create(&self, config: &[u8]) -> Result<u64, ModuleError> {
        let mut instance: u64 = 0;
        let code = unsafe {
            (self.create)(
                config.as_ptr(),
                config.len(),
                &mut instance as *mut u64,
            )
        };
        if code == 0 {
            Ok(instance)
        } else {
            Err(ModuleError::internal(format!("module create failed: code={code}")))
        }
    }

    fn call(&self, instance: Option<u64>, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
        let c_method = CString::new(method)
            .map_err(|_| ModuleError::invalid_arg("method contains NUL"))?;
        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let code = unsafe {
            (self.call)(
                instance.unwrap_or(0),
                c_method.as_ptr(),
                payload.as_ptr(),
                payload.len(),
                &mut out_ptr,
                &mut out_len,
            )
        };
        if code == ABI_OK {
            Ok(unsafe { self.copy_out(out_ptr, out_len) })
        } else if code == ABI_ERR_DETAIL {
            // 模块把结构化错误写入 out 缓冲：还原 StatusCode/code/message
            let bytes = unsafe { self.copy_out(out_ptr, out_len) };
            Err(ModuleError::from_payload(&bytes).unwrap_or_else(|| {
                ModuleError::internal(format!("module call {method} failed (undecodable detail)"))
            }))
        } else {
            Err(ModuleError::internal(format!("module call {method} failed: code={code}")))
        }
    }

    fn cancel(&self, instance: Option<u64>, request_id: &str) -> Result<(), ModuleError> {
        self.cancel_call(instance.unwrap_or(0), request_id)
    }

    fn on_event(&self, module_id: u64, kind: &str, data: &[u8]) -> Result<(), ModuleError> {
        let Some(f) = self.on_event else {
            return Ok(()); // 模块未提供 on_event（旧模块）→ 忽略下发
        };
        let c_kind = CString::new(kind)
            .map_err(|_| ModuleError::invalid_arg("kind contains NUL"))?;
        let code = unsafe { f(module_id, c_kind.as_ptr(), data.as_ptr(), data.len()) };
        if code == ABI_OK {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module on_event failed: code={code}")))
        }
    }

    fn destroy(&self, instance: u64) -> Result<(), ModuleError> {
        let code = unsafe { (self.destroy)(instance) };
        if code == 0 {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module destroy failed: code={code}")))
        }
    }

    fn shutdown(&self) {
        if let Some(f) = self.shutdown {
            unsafe { f() };
        }
    }

    fn config_binding(&self) -> Option<Arc<ModuleConfigBinding>> {
        self.config_binding.clone()
    }
}

impl Drop for DlModuleAdapter {
    fn drop(&mut self) {
        // Drop::drop runs before any field is dropped, so every subscription is
        // revoked before `_lib` (the dlopen handle) is released. Never call
        // module.shutdown() here: it must not re-enter a library we are closing.
        if let Some(binding) = &self.config_binding {
            binding.detach();
        }
    }
}

/// 定位已构建的模块 .so：缺失即 fail（避免 CI 静默跳过集成测试）。
/// 设 `GSTORE_ALLOW_MISSING_MODULE=1` 可显式跳过（返回 None）。
#[cfg(test)]
fn module_so(rel: &str) -> Option<std::path::PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
    if path.exists() {
        return Some(path);
    }
    if std::env::var("GSTORE_ALLOW_MISSING_MODULE").is_ok() {
        eprintln!(
            "SKIP (GSTORE_ALLOW_MISSING_MODULE=1): module .so not built: {}",
            path.display()
        );
        return None;
    }
    panic!(
        "module .so not built: {} — 先运行 rust/build_all.sh 构建模块，\
         或设 GSTORE_ALLOW_MISSING_MODULE=1 显式跳过",
        path.display()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 集成测试：dlopen gstore_mod_qr.so → 握手 → create → call → destroy
    /// （需先构建模块：cd rust/gstore_mod_qr && cargo build）
    #[test]
    fn dlopen_qr_module_full_roundtrip() {
        let Some(so_path) = module_so("../gstore_mod_qr/target/debug/libgstore_mod_qr.so") else { return; };

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "qr");
        assert!(adapter.version >= 1);

        // create 实例（无状态模块，返回句柄）
        let inst = adapter.create(b"{}").expect("create");
        // call ping（静态语义：实例方法）
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");
        // destroy
        adapter.destroy(inst).expect("destroy");
        // shutdown
        adapter.shutdown();
    }

    /// 通过 ModuleManager 走完整注册表链路
    #[test]
    fn module_manager_load_from_so_and_call() {
        let Some(so_path) = module_so("../gstore_mod_qr/target/debug/libgstore_mod_qr.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load from so");
        assert!(mgr.is_loaded(id));

        // 幂等：再次加载 → 同名复用同 id
        let id2 = mgr.load_module_from_so(&so_path).expect("reload");
        assert_eq!(id, id2);

        // 信封级调用（按模块名路由）
        let req = gstore_contract::envelope::EnvelopeRequest::new("qr", None, "ping", vec![]);
        let resp_bytes = mgr.call_envelope(&req.encode().unwrap());
        let resp = gstore_contract::envelope::EnvelopeResponse::decode(&resp_bytes).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        // 释放：refcount 2 → 1（仍加载）→ 0（卸载）
        mgr.unref(id);
        assert!(mgr.is_loaded(id));
        mgr.unref(id2);
        assert!(!mgr.is_loaded(id));
    }
}

/// ABI v3（`protect_fd`）兼容性测试：合成 register 不依赖 dlopen，
/// 直接走宿主的握手/gate 代码路径。
#[cfg(test)]
mod abi_v3_compat_tests {
    use super::*;
    use std::sync::Mutex;

    static CAPTURED: Mutex<Vec<(u8, u32, Option<SocketProtectFn>)>> = Mutex::new(Vec::new());
    static PROTECT_LOCK: Mutex<()> = Mutex::new(());

    extern "C" fn dummy_create(_c: *const u8, _l: usize, out: *mut u64) -> c_int {
        unsafe { *out = 1 };
        ABI_OK
    }
    extern "C" fn dummy_call(
        _i: u64,
        _m: *const c_char,
        _p: *const u8,
        _pl: usize,
        _o: *mut *mut u8,
        _ol: *mut usize,
    ) -> c_int {
        ABI_OK
    }
    extern "C" fn dummy_destroy(_i: u64) -> c_int {
        ABI_OK
    }
    extern "C" fn dummy_free(_p: *mut c_void) {}

    fn fill_api(out: *mut GStoreModuleApi, name: &'static std::ffi::CStr, min_host_abi: u32) {
        let api = unsafe { &mut *out };
        api.name = name.as_ptr();
        api.version = 1;
        api.min_host_abi = min_host_abi;
        api.init = None;
        api.create = Some(dummy_create);
        api.call = Some(dummy_call);
        api.cancel = None;
        api.destroy = Some(dummy_destroy);
        api.shutdown = None;
        api.alloc = None;
        api.free = Some(dummy_free);
        api.on_event = None;
    }

    extern "C" fn v2_register(entry: *const GStoreModuleEntry, out: *mut GStoreModuleApi) -> c_int {
        let e = unsafe { &*entry };
        CAPTURED.lock().unwrap().push((2, e.entry_size, e.protect_fd));
        fill_api(out, c"v2mod", 2);
        ABI_OK
    }

    extern "C" fn v3_register(entry: *const GStoreModuleEntry, out: *mut GStoreModuleApi) -> c_int {
        let e = unsafe { &*entry };
        CAPTURED.lock().unwrap().push((3, e.entry_size, e.protect_fd));
        fill_api(out, c"v3mod", 3);
        ABI_OK
    }

    /// (a) v2 模块（min_host_abi = 2）仍挂载 v3 宿主，且宿主注入 protect_fd。
    #[test]
    fn v2_module_still_mounts_on_v3_host_and_gets_protect_fd() {
        let _guard = PROTECT_LOCK.lock().unwrap();
        assert_eq!(GSTORE_MODULE_ABI_VERSION, 5, "宿主 ABI 已升 v5");

        let (name, api) = handshake_with(v2_register, "v2mod", 3).expect("v2 模块必须仍能挂载 v3 宿主");
        assert_eq!(name, "v2mod");
        assert_eq!(api.min_host_abi, 2);

        let (_, entry_size, protect) = *CAPTURED.lock().unwrap().last().unwrap();
        assert_eq!(
            entry_size as usize,
            GStoreModuleEntry::PLATFORM_OFFSET,
            "v3 宿主 entry_size 为 v3 布局（无 platform 槽）"
        );
        let protect = protect.expect("v3 宿主必须填充 protect_fd");
        assert_eq!(protect(7), 0, "Todo 4 接线前 stub 返回 0");
    }

    /// (b) v3 模块收到非空 protect_fd。
    #[test]
    fn v3_module_receives_non_null_protect_fd() {
        let _guard = PROTECT_LOCK.lock().unwrap();
        let (_name, api) = handshake_with(v3_register, "v3mod", 3).expect("v3 模块挂载");
        assert_eq!(api.min_host_abi, 3);
        let (_, _size, protect) = *CAPTURED.lock().unwrap().last().unwrap();
        assert!(protect.is_some(), "v3 模块必须收到非空 protect_fd");
    }

    /// (c) min_host_abi = 3 的模块被 v2 宿主拒绝（唯一 gate：min_host_abi > host_abi）。
    #[test]
    fn v2_host_rejects_min_host_abi_3_module() {
        assert!(!host_abi_satisfies(3, 2), "min_host_abi=3 模块必须被 v2 宿主拒绝");
        assert!(host_abi_satisfies(2, 2), "同版模块放行");
        assert!(host_abi_satisfies(2, 3), "v2 模块装 v3 宿主放行");
    }

    /// (d) entry_size 更小的旧 Entry：守卫跳读 protect_fd，不越界、不崩溃。
    #[test]
    fn smaller_entry_does_not_read_protect_fd() {
        let mut entry = host_entry(GSTORE_MODULE_ABI_VERSION).unwrap();
        entry.entry_size = GStoreModuleEntry::PROTECT_FD_OFFSET as u32;
        assert!(!entry.has_protect_fd());
        assert!(
            entry.protect_fd_if_present().is_none(),
            "旧 entry 必须跳过 protect_fd，不得越界读取"
        );

        let full = host_entry(GSTORE_MODULE_ABI_VERSION).unwrap();
        assert!(full.has_protect_fd());
        assert!(full.protect_fd_if_present().is_some());
    }

    /// (e) 宿主注入表按模块探测到的 ABI 逐版选择布局（具体数值断言）。
    ///
    /// 关键回归：v4 模块绝不能看到 v5 的 `entry_size`（否则它会越过 entry_size
    /// 读取并误以为 `config` 槽存在）。
    #[test]
    fn host_entry_selects_v3_v4_and_v5() {
        let v3 = host_entry(3).expect("v3 entry");
        assert_eq!(v3.abi_version, 3);
        assert_eq!(v3.entry_size as usize, GStoreModuleEntry::PLATFORM_OFFSET);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(v3.entry_size, 56, "x86_64 v3 布局 entry_size 具体数值");
        assert!(v3.platform.is_null());
        assert!(!v3.has_platform(), "v3 entry 不得暴露 platform 槽");
        assert!(!v3.has_config(), "v3 entry 不得暴露 config 槽");

        let v4 = host_entry(4).expect("v4 entry");
        assert_eq!(v4.abi_version, 4);
        assert_eq!(v4.entry_size as usize, GStoreModuleEntry::CONFIG_OFFSET);
        assert_ne!(
            v4.entry_size as usize,
            std::mem::size_of::<GStoreModuleEntry>(),
            "v4 模块绝不能收到 v5 的完整 entry_size"
        );
        #[cfg(target_pointer_width = "64")]
        assert_eq!(v4.entry_size, 64, "x86_64 v4 布局 entry_size 具体数值");
        assert!(v4.platform.is_null());
        assert!(v4.has_platform(), "v4 entry 覆盖 platform 槽");
        assert!(!v4.has_config(), "v4 entry 不得暴露 config 槽");

        let v5 = host_entry(5).expect("v5 entry");
        assert_eq!(v5.abi_version, 5);
        assert_eq!(
            v5.entry_size as usize,
            std::mem::size_of::<GStoreModuleEntry>()
        );
        #[cfg(target_pointer_width = "64")]
        assert_eq!(v5.entry_size, 72, "x86_64 v5 布局 entry_size 具体数值");
        assert!(v5.has_platform());
        assert!(v5.has_config(), "v5 entry 覆盖 config 槽");
        assert!(v5.config.is_null(), "Todo 11 接线前 config 槽保持 NULL");
        assert!(v5.config_if_present().is_none());
    }

    /// (f) ABI 越界（过旧/未来版本）拒绝，绝不静默降级。
    #[test]
    fn rejects_future_abi() {
        assert!(host_entry(6).is_err(), "v6 宿主必须被拒绝");
        assert!(host_entry(2).is_err(), "v2 宿主必须被拒绝");
    }

    /// 可替换全局：宿主 stub 可换成真实实现（Todo 4 JNI）并可复位。
    #[test]
    fn socket_protector_global_is_swappable() {
        extern "C" fn deny(_fd: c_int) -> c_int {
            -1
        }
        let _guard = PROTECT_LOCK.lock().unwrap();
        assert_eq!(current_socket_protector()(3), 0, "默认 stub 返回 0");
        set_socket_protector(deny);
        assert_eq!(current_socket_protector()(3), -1, "替换后生效");
        set_socket_protector(socket_protect_stub);
        assert_eq!(current_socket_protector()(3), 0, "恢复 stub");
    }
}

#[cfg(test)]
mod analyzer_tests {
    use super::*;
    use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};

    /// 集成测试：dlopen gstore_mod_analyzer.so → 握手 → create → call ping + 参数化方法
    /// （需先构建模块：cd rust/gstore_mod_analyzer && cargo build）
    #[test]
    fn dlopen_analyzer_module_handshake_and_call() {
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "analyzer");
        assert!(adapter.version >= 1);

        // create 实例（无状态占位）
        let inst = adapter.create(b"{}").expect("create");
        // 静态 ping
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");
        // 参数化方法：scan_dex_classes 需要一个存在的 APK，这里仅验证参数解析错误路径
        //（payload 编码：apk_path + NUL + patterns）
        let payload = b"/nonexistent.apk\0androidx.lifecycle.*".to_vec();
        let err = adapter
            .call(Some(inst), "scan_dex_classes", &payload)
            .expect_err("bad apk path should err");
        // 模块 call 失败统一转 ModuleError::internal（内部错误码），验证返回了错误即可
        assert!(!err.to_string().is_empty());

        adapter.destroy(inst).expect("destroy");
    }

    /// 通过 ModuleManager 按路径加载 analyzer 模块 + 信封级错误路由
    #[test]
    fn module_manager_loads_analyzer_from_so() {
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load analyzer");
        assert!(mgr.is_loaded(id));

        // 信封级调用 ping：按模块名 "analyzer" 路由
        let req = EnvelopeRequest::new("analyzer", None, "ping", vec![]);
        let resp_bytes = mgr.call_envelope(&req.encode().unwrap());
        let resp = EnvelopeResponse::decode(&resp_bytes).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        mgr.unref(id);
    }

    /// P0-2 回归：模块域错误经 ABI_ERR_DETAIL 透传，保留 405/METHOD_NOT_FOUND
    /// （改造前会被塌成 500/INTERNAL_ERROR）。
    #[test]
    fn module_domain_error_preserves_status_and_code() {
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load analyzer");

        let req = EnvelopeRequest::new("analyzer", None, "no_such_method", vec![])
            .with_request_id("req-err");
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert_eq!(resp.status(), 405, "应保留 MethodNotFound，而非塌成 500");
        assert_eq!(resp.error_code(), gstore_contract::error::ERR_METHOD_NOT_FOUND);

        // 缺参 → 422 INVALID_ARGUMENT（同一条透传链路）
        let req = EnvelopeRequest::new("analyzer", None, "parse_apk_info", vec![])
            .with_request_id("req-arg");
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert_eq!(resp.status(), 422);
        assert_eq!(resp.error_code(), gstore_contract::error::ERR_INVALID_ARGUMENT);

        mgr.unref(id);
    }
}

#[cfg(test)]

#[cfg(test)]
mod repo_tests {
    use super::*;
    use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};
    use std::sync::Mutex as TestMutex;

    /// 测试级互斥锁：repo/gstore_mod_repo.so 的实例状态是进程级共享的，
    /// 多个测试并发操作会互相清空（shutdown/unref clear 共享表）。
    /// 生产用 ModuleManager::global()（单例）无此问题，测试必须串行。
    static SHARED_STATE_LOCK: TestMutex<()> = TestMutex::new(());

    /// 集成测试：dlopen gstore_mod_repo.so → create（SQLite 内存库）
    /// → ping / get_one_app（空库 null）→ destroy。
    /// 验证 repo 域拆分三要素：register 符号按名解析 / 有状态实例 / 生命周期。
    /// 注：download_repo 需外网，不入单测（用 ping + 空库查询验证链路）。
    #[test]
    fn repo_module_handshake_state_and_lifecycle() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "repo");

        // create：SQLite 内存库实例（create 传 db_path config）
        let inst = adapter.create(b":memory:").expect("create instance");
        // ping
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");

        // get_one_app：空库 → JSON null（有状态 SQLite 连接可用）
        let out = adapter.call(Some(inst), "get_one_app", &[]).expect("get_one_app");
        let text = String::from_utf8_lossy(&out);
        assert_eq!(text, "null", "empty db should return null, got: {text}");

        // get_app_count：0
        let out = adapter.call(Some(inst), "get_app_count", &[]).expect("get_app_count");
        assert!(String::from_utf8_lossy(&out).contains("\"count\":0"));

        // destroy
        adapter.destroy(inst).expect("destroy");
        adapter.shutdown();
    }

    /// 通过 ModuleManager 信封级调用 repo 模块（ping 路由）
    #[test]
    fn module_manager_loads_repo_module_from_so() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load repo");
        assert!(mgr.is_loaded(id));

        // 信封级调用 ping：按模块名 "repo" 路由
        let req = EnvelopeRequest::new("repo", None, "ping", vec![]);
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        // 证书信封调用 get_one_app（需实例）：create → 信封
        let inst = mgr.call_create(id, b":memory:").expect("create");
        let req = EnvelopeRequest::new("repo", Some(&inst.to_string()), "get_one_app", vec![]);
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert!(resp.is_ok(), "resp status={} err={}", resp.status(), resp.error_message());
        assert_eq!(String::from_utf8_lossy(resp.payload()), "null");

        mgr.unref(id);
    }

    /// 下行事件烟测：向已 dlopen 的 repo 模块广播 config.changed（走 ABI on_event）
    #[test]
    fn broadcast_event_to_repo_module() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load repo");

        // 不应 panic；模块侧 on_event 解析并记录 key
        mgr.broadcast_event("config.changed", br#"{"key":"proxyUrl","value":"x"}"#);

        mgr.unref(id);
    }
}

#[cfg(test)]
mod name_tests {
    use super::*;

    #[test]
    fn parse_module_name_handles_plain_and_versioned() {
        assert_eq!(parse_module_name("libgstore_mod_qr.so").unwrap(), "qr");
        assert_eq!(parse_module_name("libgstore_mod_analyzer.so").unwrap(), "analyzer");
        assert_eq!(parse_module_name("libgstore_mod_repo.so").unwrap(), "repo");
        // 版本化文件名：剥离 _x.y.z
        assert_eq!(parse_module_name("libgstore_mod_qr_0.2.0.so").unwrap(), "qr");
        // GPU 变体：带变体后缀、以及变体+版本叠加，都应归一化回同一模块名
        assert_eq!(parse_module_name("libgstore_mod_llm_cpu.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_opencl.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_vulkan.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_opencl_1.2.3.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_repo_1.0.0.so").unwrap(), "repo");
        // 下划线模块名（无点版本）不应被误剥
        assert_eq!(parse_module_name("libgstore_mod_my_mod.so").unwrap(), "my_mod");
    }
}

/// 双向 ABI 握手证明（Todo 5）：冻结 v3 fixture ↔ 新构建 v4 模块。
///
/// 三个方向，构成追加式 ABI 演进的完整闭环：
/// - [`abi_handshake::old_module_handshake`]：冻结 v3 fixture（built @ 9ec5132，**无**
///   `gstore_mod_repo_abi` 探测符，register 只认 `abi_version == 3`）挂载 v3 宿主 entry，
///   并端到端验证 `DlModuleAdapter::load` 的「探针缺失 → 回退 v3 entry」路径；
/// - [`abi_handshake::v4_module_accepts_v3_host`]：新构建 v4 模块（探针返回 4）必须仍
///   接受 v3 宿主 entry（entry_size = 56，无 platform 槽）——追加式演进的核心证据；
/// - [`abi_handshake::v3_module_rejects_v4_entry`]：冻结 v3 fixture 的 register 收到
///   v4 宿主 entry（abi=4）必须返回 `ABI_ERR_ABI_MISMATCH` = **-2**（按其自身编译期
///   `GSTORE_MODULE_ABI_VERSION=3` 判定），而非宿主侧 name/min_host_abi 错误——负向证明
///   -2 具体码，避免「is_err 即通过」的虚假成功。
///
/// 只在 linux x86_64（fixture 布局强绑定本平台，entry_size 具体数值 56/64）。
#[cfg(all(test, target_os = "linux", target_arch = "x86_64"))]
mod abi_handshake {
    use super::*;
    use gstore_contract::abi::ABI_ERR_ABI_MISMATCH;
    use std::path::{Path, PathBuf};
    use std::sync::Once;

    /// 冻结 v3 fixture 的解析路径（相对 gstore_host 的 CARGO_MANIFEST_DIR）。
    const V3_FIXTURE_REL: &str = "../test-fixtures/v3/linux-x86_64/libgstore_mod_repo.so";
    // v4 模块源码/清单/产物（各在独立的 target/ 下，不与外层 cargo test 的 target 冲突）。
    const V4_SRC_REL: &str = "../gstore_mod_repo/src/lib.rs";
    const V4_MANIFEST_REL: &str = "../gstore_mod_repo/Cargo.toml";
    const V4_RELEASE_REL: &str = "../gstore_mod_repo/target/release/libgstore_mod_repo.so";

    /// worktree 绝对路径 = `rust/gstore_host` 往上两级（`dl_adapter.rs` 所在 crate 的 manifest 目录）。
    fn worktree_path(rel: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(rel)
    }

    fn v3_fixture_path() -> PathBuf {
        worktree_path(V3_FIXTURE_REL)
    }

    fn v4_release_path() -> PathBuf {
        worktree_path(V4_RELEASE_REL)
    }

    /// dlopen（与生产 `DlModuleAdapter::load` 相同的 RTLD_NOW | RTLD_LOCAL）。
    fn dlopen(path: &Path) -> libloading::os::unix::Library {
        unsafe {
            libloading::os::unix::Library::open(
                Some(path),
                libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_LOCAL,
            )
        }
        .unwrap_or_else(|e| panic!("dlopen {}: {e}", path.display()))
    }

    /// 解析 register 入口（同一符号约定：`gstore_mod_repo_register`）。
    fn dlsym_register(lib: &libloading::os::unix::Library) -> RegisterFn {
        let sym = unsafe { lib.get::<RegisterFn>(b"gstore_mod_repo_register\0") }
            .unwrap_or_else(|e| panic!("dlsym gstore_mod_repo_register: {e}"));
        *sym
    }

    /// 是否导出 ABI 探测符 `gstore_mod_repo_abi`（v4 有、冻结 v3 fixture 无）。
    fn has_abi_probe(lib: &libloading::os::unix::Library) -> bool {
        unsafe { lib.get::<extern "C" fn() -> u32>(b"gstore_mod_repo_abi\0") }.is_ok()
    }

    /// 确定性重建 v4 模块（进程级 Once，仅构建一次）：release .so 缺失或早于
    /// `src/lib.rs` → `cargo build --lib --release`。产物在 `gstore_mod_repo/target/`
    ///（独立于外层 `gstore_host/target/`），不会与运行中的 `cargo test` 锁冲突。
    static BUILD_V4: Once = Once::new();
    fn ensure_v4_module_built() -> PathBuf {
        BUILD_V4.call_once(|| {
            let so = v4_release_path();
            let src = worktree_path(V4_SRC_REL);
            let stale = match (
                so.metadata().and_then(|m| m.modified()).ok(),
                src.metadata().and_then(|m| m.modified()).ok(),
            ) {
                (Some(so_mtime), Some(src_mtime)) => src_mtime > so_mtime,
                _ => true,
            };
            if stale {
                let manifest = worktree_path(V4_MANIFEST_REL);
                eprintln!(
                    "abi_handshake: rebuilding v4 gstore_mod_repo (release .so stale/missing: {})",
                    so.display()
                );
                let status = std::process::Command::new("cargo")
                    .args(["build", "--manifest-path"])
                    .arg(&manifest)
                    .args(["--lib", "--release"])
                    .status()
                    .unwrap_or_else(|e| panic!("spawn cargo build for {}: {e}", manifest.display()));
                assert!(
                    status.success(),
                    "cargo build --manifest-path {} --lib --release failed (status {status})",
                    manifest.display()
                );
            }
        });
        v4_release_path()
    }

    /// 1. 冻结 v3 fixture 挂载 v3 宿主 entry（abi=3）。
    ///
    /// dlsym register → `handshake_with(register, "repo", 3)` 必须成功，`min_host_abi <= 3`；
    /// 再端到端 `DlModuleAdapter::load`，证明「探针缺失 → 回退 v3 entry」。
    #[test]
    fn old_module_handshake() {
        let fixture = v3_fixture_path();
        assert!(
            fixture.exists(),
            "frozen v3 fixture must exist (run scripts/dev/build_v3_fixture.sh at base commit 9ec5132): {}",
            fixture.display()
        );

        let lib = dlopen(&fixture);
        assert!(
            !has_abi_probe(&lib),
            "frozen v3 fixture (9ec5132) must NOT export gstore_mod_repo_abi — probe landed after it"
        );

        let v3_entry = host_entry(3).expect("host v3 entry");
        #[cfg(target_pointer_width = "64")]
        assert_eq!(v3_entry.entry_size, 56, "x86_64 v3 host entry_size concrete value");
        assert_eq!(
            v3_entry.entry_size as usize,
            GStoreModuleEntry::PLATFORM_OFFSET,
            "v3 宿主 entry 无 platform 槽"
        );

        let register = dlsym_register(&lib);
        let (name, api) = handshake_with(register, "repo", 3)
            .unwrap_or_else(|e| panic!("frozen v3 module must handshake with v3 host entry (abi=3): {e}"));
        assert_eq!(name, "repo");
        assert!(
            api.min_host_abi <= 3,
            "v3 fixture declares min_host_abi={}, host ABI=4 must satisfy it",
            api.min_host_abi
        );

        let adapter = DlModuleAdapter::load(&fixture)
            .unwrap_or_else(|e| panic!("DlModuleAdapter::load(frozen v3 fixture) must fall back to v3 entry: {e}"));
        assert_eq!(adapter.name(), "repo");
    }

    /// 2. 新构建 v4 模块必须仍接受 v3 宿主 entry。
    ///
    /// 探针值来自真实 .so 的 dlsym（非测试内常量）；`handshake_with(register, "repo", 3)`
    /// 必须 OK——v4 模块容忍 v3 宿主布局，而不是精确匹配 ABI。
    #[test]
    fn v4_module_accepts_v3_host() {
        let so = ensure_v4_module_built();
        assert!(
            so.exists(),
            "v4 module .so must exist after ensure_v4_module_built: {}",
            so.display()
        );

        let lib = dlopen(&so);
        let probe: extern "C" fn() -> u32 = unsafe {
            *lib.get(b"gstore_mod_repo_abi\0")
                .unwrap_or_else(|e| panic!("v4 module must export gstore_mod_repo_abi: {e}"))
        };
        assert_eq!(
            probe(),
            GSTORE_MODULE_ABI_VERSION,
            "模块探针(dlsym 自真实 .so)必须返回本构建 ABI"
        );

        let register = dlsym_register(&lib);
        let (name, api) = handshake_with(register, "repo", 3)
            .unwrap_or_else(|e| panic!("v4 module must accept a v3 host entry (abi=3): {e}"));
        assert_eq!(name, "repo");
        assert!(api.min_host_abi <= 3, "v4 module declares min_host_abi={}", api.min_host_abi);

        let (_name, _api) = handshake_with(register, "repo", 4)
            .unwrap_or_else(|e| panic!("v4 module must accept a v4 host entry (abi=4): {e}"));
    }

    /// 3. 冻结 v3 fixture 收到 v4 宿主 entry（abi=4）必须拒绝，且落回其编译期的
    /// `ABI_ERR_ABI_MISMATCH` = **-2**——断言返回码具体值，而不是 `is_err()`。
    #[test]
    fn v3_module_rejects_v4_entry() {
        let fixture = v3_fixture_path();
        assert!(
            fixture.exists(),
            "frozen v3 fixture must exist: {}",
            fixture.display()
        );

        let v4_entry = host_entry(4).expect("host v4 entry");
        assert_eq!(v4_entry.abi_version, 4);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(v4_entry.entry_size, 64, "x86_64 v4 host entry_size concrete value");
        assert_eq!(
            v4_entry.entry_size as usize,
            GStoreModuleEntry::CONFIG_OFFSET,
            "v4 宿主 entry 铺满 platform 槽、但不含 v5 config 槽"
        );
        assert!(!v4_entry.has_config(), "v4 宿主 entry 不得暴露 config");

        let lib = dlopen(&fixture);
        let register = dlsym_register(&lib);
        assert!(
            !has_abi_probe(&lib),
            "frozen v3 fixture must not export gstore_mod_repo_abi (its register compiled against ABI 3)"
        );

        let err = match handshake_with(register, "repo", 4) {
            Err(e) => e,
            Ok(_) => panic!("frozen v3 module must reject a v4 host entry (abi=4)"),
        };
        assert_eq!(ABI_ERR_ABI_MISMATCH, -2, "ABI_ERR_ABI_MISMATCH 具体值回归");
        assert!(
            err.contains(&format!("code={}", ABI_ERR_ABI_MISMATCH)),
            "expected module rejection code=-2 (ABI_ERR_ABI_MISMATCH) in: {err}"
        );
        assert!(
            !err.contains("unsupported module ABI")
                && !err.contains("requires host ABI")
                && !err.contains("name mismatch"),
            "must be the module's own -2 rejection, not a host-side gate error: {err}"
        );
    }
}

#[cfg(test)]
mod module_config_tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, AtomicUsize};
    use std::sync::MutexGuard;

    use gstore_core::config::ConfigStore;
    use gstore_core::db::DbHandle;
    use gstore_core::ports::FileSecretStore;

    static SERIAL: Mutex<()> = Mutex::new(());
    static NEXT_MODULE_ID: AtomicU64 = AtomicU64::new(10_000);

    fn serial() -> MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(tag: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "gstore_module_config_{tag}_{}_{}",
                std::process::id(),
                NEXT_MODULE_ID.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join("data")).expect("create data dir");
            let db = DbHandle::open(&root.join("data")).expect("open core db");
            let secrets = Arc::new(FileSecretStore::new(root.join("data").join("secrets")));
            let store = Arc::new(ConfigStore::new(db.clone(), secrets));
            store.load_all().expect("load config store");
            let bus = Arc::new(ConfigBus::new());
            crate::config_api::install_core_config(store, bus, db);
            Self { root }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            crate::config_api::reset_store_for_test();
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[derive(Default)]
    struct Recorder {
        changes: Mutex<Vec<Value>>,
    }

    impl Recorder {
        fn new() -> Arc<Self> {
            Arc::new(Self::default())
        }

        fn changes(&self) -> Vec<Value> {
            self.changes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone()
        }

        fn keys(&self) -> Vec<String> {
            self.changes()
                .iter()
                .filter_map(|change| {
                    let module = change.get("module")?.as_str()?;
                    let key = change.get("key")?.as_str()?;
                    Some(format!("{module}.{key}"))
                })
                .collect()
        }

        fn push(&self, change: Value) {
            self.changes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(change);
        }
    }

    extern "C" fn record(user: *mut c_void, change: *const c_char) -> c_int {
        if user.is_null() || change.is_null() {
            return ABI_ERR_CONFIG_INVALID;
        }
        // SAFETY: the test owns the leaked Recorder passed as user_ctx; the
        // change string lives only for this call and is copied immediately.
        let recorder = unsafe { &*(user as *const Recorder) };
        let text = unsafe { CStr::from_ptr(change) }.to_string_lossy();
        match serde_json::from_str::<Value>(&text) {
            Ok(value) => recorder.push(value),
            Err(_) => return ABI_ERR_CONFIG_INVALID,
        }
        ABI_OK
    }

    struct TestModule {
        binding: Arc<ModuleConfigBinding>,
        vtable: GStoreConfigApiV1,
    }

    impl TestModule {
        fn new(name: &str) -> Self {
            let id = NEXT_MODULE_ID.fetch_add(1, Ordering::Relaxed);
            let binding = ModuleConfigBinding::new(id, name);
            let vtable = build_config_vtable(&binding);
            Self { binding, vtable }
        }

        fn ctx(&self) -> *mut c_void {
            self.vtable.context
        }

        fn subscribe(
            &self,
            target: Option<&str>,
            key: Option<&str>,
            recorder: &Arc<Recorder>,
        ) -> Result<u64, c_int> {
            let target = target.map(|text| CString::new(text).expect("target CString"));
            let key = key.map(|text| CString::new(text).expect("key CString"));
            let user = Arc::into_raw(Arc::clone(recorder)) as *mut c_void;
            let mut token = 0u64;
            let code = config_subscribe(
                self.ctx(),
                target.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                key.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                user,
                Some(record),
                &mut token,
            );
            if code == ABI_OK {
                Ok(token)
            } else {
                Err(code)
            }
        }

        fn subscribe_with(
            &self,
            target: Option<&str>,
            key: Option<&str>,
            user: *mut c_void,
            callback: ChangeCallback,
        ) -> Result<u64, c_int> {
            let target = target.map(|text| CString::new(text).expect("target CString"));
            let key = key.map(|text| CString::new(text).expect("key CString"));
            let mut token = 0u64;
            let code = config_subscribe(
                self.ctx(),
                target.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                key.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                user,
                Some(callback),
                &mut token,
            );
            if code == ABI_OK {
                Ok(token)
            } else {
                Err(code)
            }
        }

        fn unsubscribe(&self, token: u64) -> c_int {
            config_unsubscribe(self.ctx(), token)
        }

        fn get(&self, target: Option<&str>, key: &str) -> Result<Value, c_int> {
            self.get_result(target, key).map_err(|(code, _)| code)
        }

        fn get_result(&self, target: Option<&str>, key: &str) -> Result<Value, (c_int, String)> {
            let target = target.map(|text| CString::new(text).expect("target CString"));
            let key = CString::new(key).expect("key CString");
            let mut out = ByteBuf {
                ptr: std::ptr::null_mut(),
                len: 0,
            };
            let code = config_get(
                self.ctx(),
                target.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                key.as_ptr(),
                &mut out,
            );
            if code != ABI_OK {
                return Err((code, String::new()));
            }
            // SAFETY: on success the host filled `out` with a buffer it owns;
            // copy it and hand it back through the vtable's free_buf.
            let text = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
            config_free_buf(out);
            serde_json::from_slice(&text).map_err(|_| (ABI_ERR_CONFIG_INVALID, String::new()))
        }

        fn set(&self, key: &str, value_json: &str) -> c_int {
            let key = CString::new(key).expect("key CString");
            let value = CString::new(value_json).expect("value CString");
            config_set(self.ctx(), key.as_ptr(), value.as_ptr())
        }

        fn list(&self, target: Option<&str>) -> Result<Value, c_int> {
            let target = target.map(|text| CString::new(text).expect("target CString"));
            let mut out = ByteBuf {
                ptr: std::ptr::null_mut(),
                len: 0,
            };
            let code = config_list(
                self.ctx(),
                target.as_ref().map_or(std::ptr::null(), |text| text.as_ptr()),
                &mut out,
            );
            if code != ABI_OK {
                return Err(code);
            }
            // SAFETY: same host-owned buffer contract as `get_result`.
            let text = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
            config_free_buf(out);
            serde_json::from_slice(&text).map_err(|_| ABI_ERR_CONFIG_INVALID)
        }
    }

    fn commit(module: &str, key: &str, value_json: &str) {
        crate::config_api::set(
            module.to_string(),
            key.to_string(),
            value_json.to_string(),
            "user".to_string(),
        )
        .expect("commit config change");
    }

    fn build_fixture_so(name: &str, min_host_abi: u32) -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target/module_config_fixtures/unit");
        std::fs::create_dir_all(&dir).expect("create unit fixture dir");
        let output = dir.join(format!("libgstore_mod_{name}.so"));
        let source =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/config_module.c");
        let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
        let status = std::process::Command::new(cc)
            .args(["-shared", "-fPIC", "-std=c99", "-Wall", "-Wextra", "-Werror"])
            .arg(format!("-DFIXTURE_NAME={name}"))
            .arg(format!("-DFIXTURE_MIN_HOST_ABI={min_host_abi}"))
            .arg("-o")
            .arg(&output)
            .arg(&source)
            .status()
            .expect("spawn cc for unit fixture");
        assert!(status.success(), "C fixture compile failed: {status}");
        output
    }

    fn record_count(path: &std::path::Path, prefix: &str) -> usize {
        std::fs::read_to_string(path)
            .map(|text| {
                text.lines()
                    .filter(|line| line.starts_with(prefix))
                    .count()
            })
            .unwrap_or(0)
    }

    fn wait_record_count(path: &std::path::Path, prefix: &str, expected: usize) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while std::time::Instant::now() < deadline {
            if record_count(path, prefix) >= expected {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn module_config_download_only_subscriber_is_called_theme_is_not() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("routing");
        let download = TestModule::new("download");
        let theme = TestModule::new("theme");
        let download_recorder = Recorder::new();
        let theme_recorder = Recorder::new();
        download
            .subscribe(None, None, &download_recorder)
            .expect("download subscription");
        theme
            .subscribe(None, None, &theme_recorder)
            .expect("theme subscription");

        commit("download", "max_concurrent", "5");

        assert_eq!(download_recorder.keys(), vec!["download.max_concurrent"]);
        assert!(theme_recorder.changes().is_empty(), "theme must not observe download");
    }

    #[test]
    fn module_config_exact_key_receives_only_that_key() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("exact");
        let download = TestModule::new("download");
        let recorder = Recorder::new();
        download
            .subscribe(None, Some("max_concurrent"), &recorder)
            .expect("exact-key subscription");

        commit("download", "max_concurrent", "6");
        commit("download", "default_connections", "3");

        assert_eq!(recorder.keys(), vec!["download.max_concurrent"]);
    }

    #[test]
    fn module_config_foreign_whole_module_is_not_a_blanket_grant() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("foreign-owner");
        let foreign = TestModule::new("download");
        let recorder = Recorder::new();
        foreign
            .subscribe(Some("theme"), None, &recorder)
            .expect("foreign whole-module subscription");

        commit("theme", "config", r#"{"dark":true}"#);
        assert!(
            recorder.changes().is_empty(),
            "a later Owner key must not reach a foreign key=None subscription"
        );

        commit("theme", "mode", "2");
        assert_eq!(recorder.keys(), vec!["theme.mode"]);
    }

    #[test]
    fn module_config_public_read_cross_module_change_is_delivered() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("publicread");
        let foreign = TestModule::new("download");
        let recorder = Recorder::new();
        foreign
            .subscribe(Some("theme"), Some("mode"), &recorder)
            .expect("PublicRead exact-key subscription");

        commit("theme", "mode", "1");

        assert_eq!(recorder.keys(), vec!["theme.mode"]);
    }

    #[test]
    fn module_config_unsubscribe_validates_ownership_and_stale_generations() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("tokens");
        let download = TestModule::new("download");
        let other = TestModule::new("theme");
        let recorder = Recorder::new();
        let first = download
            .subscribe(None, None, &recorder)
            .expect("first subscription");
        let second = download
            .subscribe(None, None, &recorder)
            .expect("second subscription");

        assert_eq!(
            other.unsubscribe(first),
            ABI_ERR_CONFIG_BAD_TOKEN,
            "a foreign module cannot unsubscribe another module's token"
        );
        assert_eq!(download.unsubscribe(second), ABI_OK);
        commit("download", "max_concurrent", "7");
        assert_eq!(recorder.keys(), vec!["download.max_concurrent"]);

        clear_module_config_sinks();
        assert_eq!(
            download.unsubscribe(first),
            ABI_ERR_CONFIG_BAD_TOKEN,
            "a stale-generation token is gone after reset"
        );
        commit("download", "max_concurrent", "8");
        assert_eq!(recorder.keys().len(), 1, "no delivery after clearing sinks");
    }

    struct UnloadRecorder {
        recorder: Arc<Recorder>,
        binding: Arc<ModuleConfigBinding>,
        module: Arc<dyn GStoreModule>,
    }

    extern "C" fn record_then_unload(user: *mut c_void, change: *const c_char) -> c_int {
        if user.is_null() {
            return ABI_ERR_CONFIG_INVALID;
        }
        // SAFETY: the test leaks this UnloadRecorder for the callbacks' lifetime.
        let state = unsafe { &*(user as *const UnloadRecorder) };
        let code = record(Arc::as_ptr(&state.recorder) as *mut c_void, change);
        state.binding.begin_unload(Arc::clone(&state.module));
        code
    }

    struct CountingModule {
        shutdowns: Arc<AtomicUsize>,
        config: Option<Arc<ModuleConfigBinding>>,
    }

    impl GStoreModule for CountingModule {
        fn name(&self) -> &'static str {
            "counting"
        }
        fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
            Ok(1)
        }
        fn call(
            &self,
            _instance: Option<u64>,
            method: &str,
            _payload: &[u8],
        ) -> Result<Vec<u8>, ModuleError> {
            Err(ModuleError::method_not_found(method))
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
        fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
        }
        fn config_binding(&self) -> Option<Arc<ModuleConfigBinding>> {
            self.config.clone()
        }
    }

    #[test]
    fn module_config_unload_during_delivery_defers_shutdown_and_stops_delivery() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("unload");
        let download = TestModule::new("download");
        let shutdowns = Arc::new(AtomicUsize::new(0));
        let module: Arc<dyn GStoreModule> = Arc::new(CountingModule {
            shutdowns: Arc::clone(&shutdowns),
            config: None,
        });
        let state = Box::into_raw(Box::new(UnloadRecorder {
            recorder: Recorder::new(),
            binding: Arc::clone(&download.binding),
            module: Arc::clone(&module),
        }));
        download
            .subscribe_with(None, None, state.cast(), record_then_unload)
            .expect("unloading subscription");

        commit("download", "max_concurrent", "9");
        // SAFETY: state is leaked for the module lifetime (test scope).
        let delivered = unsafe { &*state }.recorder.keys();
        assert_eq!(delivered, vec!["download.max_concurrent"]);
        assert_eq!(shutdowns.load(Ordering::SeqCst), 1, "deferred shutdown ran once");
        assert!(download.binding.is_unloaded());

        commit("download", "max_concurrent", "10");
        // SAFETY: same leaked state.
        assert_eq!(
            unsafe { &*state }.recorder.keys().len(),
            1,
            "no callback after unload"
        );
    }

    #[test]
    fn module_config_detach_revokes_subscriptions_without_shutdown() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("detach");
        let download = TestModule::new("download");
        let recorder = Recorder::new();
        download
            .subscribe(None, None, &recorder)
            .expect("subscription");

        let generation = download.binding.generation();
        download.binding.detach();

        assert!(download.binding.is_unloaded());
        assert!(download.binding.generation() > generation);
        assert!(lock_registry().subscriptions.is_empty());
        download.binding.detach();
        assert!(lock_registry().subscriptions.is_empty());

        commit("download", "max_concurrent", "5");
        assert!(recorder.changes().is_empty(), "detached binding must not deliver");
    }

    #[test]
    fn module_config_adapter_drop_keeps_library_mapped_during_callback() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("drop-race");
        let dir = std::env::temp_dir().join(format!(
            "gstore_drop_race_{}_{}",
            std::process::id(),
            NEXT_MODULE_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create drop-race dir");
        let record = dir.join("deliveries.log");
        std::env::set_var("GS_CONFIG_RECORD_FILE", &record);
        std::env::set_var("GS_CONFIG_SLOW_MS", "1200");

        let so = build_fixture_so("download", 5);
        let adapter =
            DlModuleAdapter::load_with_module_id(&so, 77_001).expect("load ABI v5 fixture");
        let binding = adapter.config_binding().expect("config binding");
        let setter = std::thread::spawn(|| commit("download", "max_concurrent", "5"));
        assert!(
            wait_record_count(&record, "enter ", 1),
            "callback must enter before the adapter is dropped"
        );

        // The callback is still inside the .so while Drop::drop runs. The
        // binding's process-lifetime library keepalive must keep the code page
        // mapped; no wait/shutdown is needed.
        drop(adapter);
        setter.join().expect("setter joined");

        assert!(binding.is_unloaded());
        assert!(
            binding
                .library
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_some(),
            "detach must not clear the library keepalive"
        );
        assert_eq!(
            record_count(&record, "deliver "),
            1,
            "the in-flight callback must complete after the adapter was dropped"
        );

        commit("download", "max_concurrent", "3");
        assert_eq!(
            record_count(&record, "deliver "),
            1,
            "detached binding must not receive later changes"
        );

        std::env::remove_var("GS_CONFIG_RECORD_FILE");
        std::env::remove_var("GS_CONFIG_SLOW_MS");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn module_config_unref_clears_subscriptions_and_runs_shutdown() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("unref");
        let shutdowns = Arc::new(AtomicUsize::new(0));
        let binding = ModuleConfigBinding::new(42_424, "download");
        let module = Arc::new(CountingModule {
            shutdowns: Arc::clone(&shutdowns),
            config: Some(Arc::clone(&binding)),
        });
        let manager = crate::manager::ModuleManager::new();
        let id = manager.insert_module(Some(42_424), module.clone(), false);
        let recorder = Recorder::new();
        let vtable = build_config_vtable(&binding);
        let mut token = 0u64;
        let user = Arc::into_raw(Arc::clone(&recorder)) as *mut c_void;
        assert_eq!(
            config_subscribe(
                vtable.context,
                std::ptr::null(),
                std::ptr::null(),
                user,
                Some(record),
                &mut token,
            ),
            ABI_OK
        );

        manager.unref(id);

        assert_eq!(shutdowns.load(Ordering::SeqCst), 1);
        assert!(binding.is_unloaded());
        let registry = lock_registry();
        assert!(
            registry.subscriptions.is_empty(),
            "unref must clear every subscription owned by the module"
        );
    }

    #[test]
    fn module_config_boundary_rejects_malformed_and_enforces_visibility() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("boundary");
        let download = TestModule::new("download");
        let theme = TestModule::new("theme");
        let webdav = TestModule::new("webdav");

        assert_eq!(
            download.set("max_concurrent", "{not json"),
            ABI_ERR_CONFIG_INVALID,
            "malformed JSON must be rejected at the boundary"
        );
        assert_eq!(
            download.set("max_concurrent", r#""not-an-int""#),
            ABI_ERR_CONFIG_INVALID,
            "wrong JSON type must be rejected"
        );
        assert_eq!(
            download.get(None, "nope").unwrap_err(),
            ABI_ERR_CONFIG_NOT_FOUND
        );
        assert_eq!(
            download.get(Some("theme"), "config").unwrap_err(),
            ABI_ERR_CONFIG_FORBIDDEN,
            "foreign Owner reads are forbidden"
        );
        assert_eq!(
            download.get(Some("webdav"), "password").unwrap_err(),
            ABI_ERR_CONFIG_FORBIDDEN,
            "foreign Secret reads are forbidden"
        );

        assert_eq!(webdav.set("password", r#""s3cret""#), ABI_OK);
        assert_eq!(
            webdav.get(None, "password").expect("own raw secret"),
            serde_json::json!("s3cret"),
            "own-module reads are trusted raw"
        );
        assert_eq!(
            download.get(Some("webdav"), "password").unwrap_err(),
            ABI_ERR_CONFIG_FORBIDDEN
        );

        let listed = theme.list(None).expect("own list");
        let arrays = listed.as_array().expect("list array");
        assert!(arrays.iter().any(|item| item["key"] == "mode"));
        assert!(arrays.iter().any(|item| item["key"] == "config"));

        let foreign = download.list(Some("theme")).expect("foreign list");
        let arrays = foreign.as_array().expect("list array");
        assert!(
            arrays.iter().all(|item| item["visibility"] == "public_read"),
            "foreign list exposes only PublicRead entries: {foreign}"
        );
        assert!(arrays.iter().any(|item| item["key"] == "mode"));
        assert!(arrays.iter().all(|item| item["key"] != "config"));
    }

    #[test]
    fn module_config_module_without_subscription_or_on_event_does_not_break_write() {
        let _guard = serial();
        clear_module_config_sinks();
        let _fixture = Fixture::new("no-sub");
        let theme = TestModule::new("theme");
        let recorder = Recorder::new();
        theme
            .subscribe(None, None, &recorder)
            .expect("theme subscription");

        assert_eq!(
            crate::config_api::set(
                "download".to_string(),
                "max_concurrent".to_string(),
                "4".to_string(),
                "module".to_string(),
            )
            .map(|_| ())
            .map_err(|error| error.to_string()),
            Ok(()),
            "a write with no on_event/subscriber must still commit"
        );
        assert!(recorder.changes().is_empty());
    }

}
