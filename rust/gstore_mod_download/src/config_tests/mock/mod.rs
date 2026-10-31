//! Mock host implementing the committed ABI v5 config vtable.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;

use gstore_contract::abi::{GStoreConfigApiV1, CONFIG_CAP_ALL, GSTORE_MODULE_ABI_VERSION};
use serde_json::{json, Value};

mod ffi;

pub(crate) type Callback =
    extern "C" fn(user_ctx: *mut c_void, change_json: *const c_char) -> c_int;

#[derive(Clone)]
pub(crate) struct MockSubscription {
    token: u64,
    module: String,
    key: Option<String>,
    user: usize,
    callback: Callback,
}

pub(crate) struct MockHost {
    store: Mutex<HashMap<(String, String), Value>>,
    subscriptions: Mutex<Vec<MockSubscription>>,
    calls: Mutex<Vec<String>>,
    pending: Mutex<Vec<(String, String, Value)>>,
    next_token: AtomicU64,
    delivered: AtomicUsize,
}

impl MockHost {
    pub(crate) fn new() -> Self {
        Self {
            store: Mutex::new(HashMap::new()),
            subscriptions: Mutex::new(Vec::new()),
            calls: Mutex::new(Vec::new()),
            pending: Mutex::new(Vec::new()),
            next_token: AtomicU64::new(1),
            delivered: AtomicUsize::new(0),
        }
    }

    pub(crate) fn vtable(&self) -> GStoreConfigApiV1 {
        GStoreConfigApiV1 {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            struct_size: std::mem::size_of::<GStoreConfigApiV1>() as u32,
            capabilities: CONFIG_CAP_ALL,
            context: self as *const Self as *mut c_void,
            get: Some(ffi::mock_get),
            set: Some(ffi::mock_set),
            list: Some(ffi::mock_list),
            subscribe: Some(ffi::mock_subscribe),
            unsubscribe: Some(ffi::mock_unsubscribe),
            free_buf: Some(ffi::mock_free_buf),
        }
    }

    pub(crate) fn call_log(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    pub(crate) fn delivered_count(&self) -> usize {
        self.delivered.load(Ordering::SeqCst)
    }

    pub(crate) fn subscriptions(&self) -> Vec<(String, Option<String>)> {
        self.subscriptions
            .lock()
            .unwrap()
            .iter()
            .map(|s| (s.module.clone(), s.key.clone()))
            .collect()
    }

    pub(crate) fn stored(&self, module: &str, key: &str) -> Option<Value> {
        self.store
            .lock()
            .unwrap()
            .get(&(module.to_string(), key.to_string()))
            .cloned()
    }

    /// Host-authoritative write: commit then publish to matching subscriptions.
    pub(crate) fn set_value(&self, module: &str, key: &str, value: Value) {
        self.calls
            .lock()
            .unwrap()
            .push(format!("change:{module}:{key}"));
        self.store
            .lock()
            .unwrap()
            .insert((module.to_string(), key.to_string()), value.clone());
        self.deliver(module, key, &value);
    }

    /// Seeds a value without publishing (simulates a value already in the store).
    pub(crate) fn prime(&self, module: &str, key: &str, value: Value) {
        self.store
            .lock()
            .unwrap()
            .insert((module.to_string(), key.to_string()), value);
    }

    /// Queues a change that is committed immediately before the module's first
    /// `subscribe` call returns, simulating the subscribe/read window.
    pub(crate) fn queue_during_subscribe(&self, module: &str, key: &str, value: Value) {
        self.store
            .lock()
            .unwrap()
            .insert((module.to_string(), key.to_string()), value.clone());
        self.pending
            .lock()
            .unwrap()
            .push((module.to_string(), key.to_string(), value));
    }

    fn deliver(&self, module: &str, key: &str, value: &Value) {
        let payload = json!({
            "module": module,
            "key": key,
            "value": value,
            "oldValue": null,
            "revision": 1,
            "source": "module",
        })
        .to_string();
        let payload = CString::new(payload).expect("test payload has no NUL");
        let matching: Vec<MockSubscription> = self
            .subscriptions
            .lock()
            .unwrap()
            .iter()
            .filter(|sub| sub.module == module && sub.key.as_deref().is_none_or(|k| k == key))
            .cloned()
            .collect();
        for subscription in matching {
            self.delivered.fetch_add(1, Ordering::SeqCst);
            (subscription.callback)(subscription.user as *mut c_void, payload.as_ptr());
        }
    }

    fn flush_pending(&self) {
        let pending: Vec<_> = self.pending.lock().unwrap().drain(..).collect();
        for (module, key, value) in pending {
            self.deliver(&module, &key, &value);
        }
    }
}
