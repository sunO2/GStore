//! Host → `gstore_mod_proxy` TUN fd delivery (Todo 6 hand-off gap).
//!
//! ## Why this exists
//!
//! `nativeSetTunFd` (Kotlin `ProxyVpnService`) only *stores* the fd in
//! [`crate::jni_bridge`]. Before Todo 6 there was no path across the `.so`
//! boundary into the loaded `proxy` module, so the module could never start its
//! TUN reader. This module closes that gap.
//!
//! ## Chosen design (recorded, per plan Todo 6)
//!
//! **Host-push with pending retention + flush-on-mount.**
//!
//! 1. On `nativeSetTunFd`, the host stores the fd (`jni_bridge::TUN_FD`) and
//!    immediately forwards it to the `proxy` module via a normal module `call`
//!    of `tun.set_fd` (`{"fd":<i32>}`) — no new ABI slot, so nothing in
//!    `gstore_contract` changes.
//! 2. If the `proxy` module is not mounted yet, the fd simply stays in the host.
//!    When `proxy` is later registered (`ModuleManager::register_inner`), the
//!    pending fd is flushed with the same `tun.set_fd` call. This makes the
//!    delivery order-independent between "Kotlin establishes the tunnel" and
//!    "Dart mounts/calls the proxy module".
//! 3. `tun.set_fd` is a **module-global** method (instance-less; the proxy
//!    process has exactly one tunnel, and lwIP's pcb lists are process globals),
//!    so the host does not need to track an instance id.
//!
//! The reverse direction uses events: when the module's `core.stop` has stopped
//! the loop and joined its thread it emits `proxy.tun.released`; the host
//! intercepts it here and clears its cached fd so Kotlin's `nativeClear` +
//! `ParcelFileDescriptor.close()` are safe.

use crate::manager::ModuleManager;

/// Module name the fd is delivered to (matches `api.name` in the module ABI).
pub(crate) const PROXY_MODULE: &str = "proxy";

/// Event the module emits once its TUN read loop has fully stopped + joined.
pub(crate) const EVT_TUN_RELEASED: &str = "proxy.tun.released";

/// Forward `fd` to the `proxy` module's `tun.set_fd`. Returns `true` on success
/// (or when `fd < 0`, which is a no-op). Never panics: a failed delivery only
/// logs, leaving the fd cached for a later flush.
pub(crate) fn deliver_tun_fd_to(mgr: &ModuleManager, fd: i32) -> bool {
    if fd < 0 {
        return false;
    }
    let Some(module_id) = mgr.module_id_by_name(PROXY_MODULE) else {
        crate::log_bridge::push_host_log(
            2,
            format!("tun_bridge: proxy module not mounted yet; fd={fd} kept pending"),
        );
        return false;
    };
    let payload = format!(r#"{{"fd":{fd}}}"#);
    match mgr.call(module_id, None, "tun.set_fd", payload.as_bytes()) {
        Ok(_) => {
            crate::log_bridge::push_host_log(
                1,
                format!("tun_bridge: delivered TUN fd={fd} to proxy module"),
            );
            true
        }
        Err(e) => {
            crate::log_bridge::push_host_log(
                3,
                format!("tun_bridge: proxy tun.set_fd failed: {e}"),
            );
            false
        }
    }
}

/// Deliver the currently cached host TUN fd, if any, to the global manager's
/// `proxy` module. Called from `nativeSetTunFd` and on proxy mount.
pub(crate) fn deliver_pending_tun_fd() -> bool {
    let fd = crate::jni_bridge::current_tun_fd();
    deliver_tun_fd_to(ModuleManager::global(), fd)
}

/// Host-side reaction to module events. Clears the cached fd when the module
/// reports its reader loop has stopped and its thread has joined.
pub(crate) fn on_module_event(event_type: &str, payload: &[u8]) {
    if event_type != EVT_TUN_RELEASED {
        return;
    }
    let fd = serde_json::from_slice::<serde_json::Value>(payload)
        .ok()
        .and_then(|v| v.get("fd").and_then(|f| f.as_i64()))
        .map(|f| f as i32)
        .unwrap_or(-1);
    crate::jni_bridge::note_tun_released(fd);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manager::GStoreModule;
    use gstore_contract::error::ModuleError;
    use std::sync::{Arc, Mutex};

    use crate::TEST_SERIAL as TEST_LOCK;

    /// Records every `tun.set_fd` payload it receives.
    struct ProxyRecorder {
        seen: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl GStoreModule for ProxyRecorder {
        fn name(&self) -> &'static str {
            "proxy"
        }
        fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
            Ok(1)
        }
        fn call(
            &self,
            _instance: Option<u64>,
            method: &str,
            payload: &[u8],
        ) -> Result<Vec<u8>, ModuleError> {
            if method == "tun.set_fd" {
                self.seen.lock().unwrap().push(payload.to_vec());
                let v: serde_json::Value = serde_json::from_slice(payload).unwrap();
                assert!(v["fd"].is_i64(), "fd must be an integer");
                return Ok(br#"{"ok":true,"data":{"nonblocking":true}}"#.to_vec());
            }
            Err(ModuleError::method_not_found(method))
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }

    #[test]
    fn deliver_forwards_integer_fd_to_proxy_module() {
        let mgr = ModuleManager::new();
        let seen = Arc::new(Mutex::new(Vec::new()));
        mgr.register(Arc::new(ProxyRecorder { seen: seen.clone() }));

        assert!(deliver_tun_fd_to(&mgr, 42));
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        let v: serde_json::Value = serde_json::from_slice(&seen[0]).unwrap();
        assert_eq!(v["fd"], 42);
    }

    #[test]
    fn deliver_without_module_is_pending_and_negative_is_noop() {
        let mgr = ModuleManager::new();
        assert!(!deliver_tun_fd_to(&mgr, 7), "no proxy module → pending");
        assert!(!deliver_tun_fd_to(&mgr, -1), "negative fd → no-op");
    }

    /// Global fd cache lifecycle around a release event.
    #[test]
    fn release_event_clears_matching_cached_fd() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::jni_bridge::clear_impl();
        assert_eq!(crate::jni_bridge::current_tun_fd(), -1);

        crate::jni_bridge::set_tun_fd_impl(55).unwrap();
        assert_eq!(crate::jni_bridge::current_tun_fd(), 55);
        // A non-matching release must not clear the cache.
        on_module_event(EVT_TUN_RELEASED, br#"{"fd":99}"#);
        assert_eq!(crate::jni_bridge::current_tun_fd(), 55);
        // The matching release clears it.
        on_module_event(EVT_TUN_RELEASED, br#"{"fd":55}"#);
        assert_eq!(crate::jni_bridge::current_tun_fd(), -1);

        crate::jni_bridge::clear_impl();
    }

    #[test]
    fn non_release_event_is_ignored() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::jni_bridge::clear_impl();
        crate::jni_bridge::set_tun_fd_impl(66).unwrap();
        on_module_event("proxy.state", br#"{"state":"stopped"}"#);
        assert_eq!(crate::jni_bridge::current_tun_fd(), 66);
        crate::jni_bridge::clear_impl();
    }

    /// `nativeSetTunFd` can arrive before the proxy module mounts; the fd must be
    /// flushed by `ModuleManager::register_inner` when `proxy` appears.
    #[test]
    fn pending_fd_is_flushed_when_proxy_mounts_later() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::jni_bridge::clear_impl();
        crate::jni_bridge::set_tun_fd_impl(77).unwrap();
        assert_eq!(crate::jni_bridge::current_tun_fd(), 77, "fd cached pre-mount");

        let seen = Arc::new(Mutex::new(Vec::new()));
        let mgr = ModuleManager::global();
        assert!(mgr.module_id_by_name("proxy").is_none(), "test must start clean");
        let id = mgr.register(Arc::new(ProxyRecorder { seen: seen.clone() }));
        {
            let s = seen.lock().unwrap();
            assert_eq!(s.len(), 1, "pending fd must be flushed on proxy mount");
            let v: serde_json::Value = serde_json::from_slice(&s[0]).unwrap();
            assert_eq!(v["fd"], 77);
        }
        mgr.unref(id);
        assert!(mgr.module_id_by_name("proxy").is_none(), "cleanup");
        crate::jni_bridge::clear_impl();
    }

    /// Engine / Dart-isolate restart (Activity recreation): the host bridges are
    /// reset, but the Rust kernel (module + tunnel fd) keeps running and events
    /// resume on the new subscription. Todo 24 requirement (a).
    #[test]
    fn engine_restart_keeps_tunnel_and_resumes_events() {
        let _g = TEST_LOCK.lock().unwrap();
        crate::jni_bridge::clear_impl();
        crate::event_bridge::clear_buffer_for_tests();

        let seen = Arc::new(Mutex::new(Vec::new()));
        let mgr = ModuleManager::global();
        assert!(mgr.module_id_by_name("proxy").is_none(), "test must start clean");
        let id = mgr.register(Arc::new(ProxyRecorder { seen: seen.clone() }));

        // Kotlin established the tunnel, then a live module event arrived.
        crate::jni_bridge::set_tun_fd_impl(5150).unwrap();
        crate::event_bridge::push_event(1, 1, "proxy.state", br#"{"state":"running"}"#.to_vec());
        assert!(crate::event_bridge::last_event_for_tests().is_some());

        crate::bridge::HostInspector::new().reset_bridges();

        // (a) the tunnel fd survives and the kernel stays mounted.
        assert_eq!(
            crate::jni_bridge::current_tun_fd(),
            5150,
            "tunnel must survive an engine restart"
        );
        assert!(
            mgr.module_id_by_name("proxy").is_some(),
            "the Rust kernel must stay mounted"
        );

        // (b) events resume on the restarted isolate's subscription.
        crate::event_bridge::push_event(
            1,
            1,
            "proxy.state",
            br#"{"state":"running","reason":"after_restart"}"#.to_vec(),
        );
        let (event_type, data) = crate::event_bridge::last_event_for_tests().unwrap();
        assert_eq!(event_type, "proxy.state");
        assert!(String::from_utf8_lossy(&data).contains("after_restart"));

        // (c) the fd was delivered exactly once (no re-mount / re-delivery) and
        // no task was leaked by the bridge reset.
        assert_eq!(seen.lock().unwrap().len(), 1, "tun.set_fd delivered exactly once");
        assert_eq!(crate::task_bridge::running_task_count(), 0);

        mgr.unref(id);
        crate::jni_bridge::clear_impl();
    }
}
