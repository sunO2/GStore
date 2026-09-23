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

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};

use crate::jni_bridge::UidQueryHost;
use crate::manager::ModuleManager;

/// Module name the fd is delivered to (matches `api.name` in the module ABI).
pub(crate) const PROXY_MODULE: &str = "proxy";

/// Event the module emits once its TUN read loop has fully stopped + joined.
pub(crate) const EVT_TUN_RELEASED: &str = "proxy.tun.released";

/// Internal module → host event asking for a flow's owning Android uid.
pub(crate) const EVT_UID_QUERY: &str = "proxy.uid.query";

/// Host → module reply carrying the resolved uids.
pub(crate) const EVT_UID_RESULT: &str = "uid.result";

/// Bounded queue capacity for pending host uid queries.
pub(crate) const UID_QUERY_QUEUE_CAP: usize = 256;

/// Maximum queries handed to a single `resolve_uids` call.
pub(crate) const UID_BATCH_MAX: usize = 64;

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

/// Host-side reaction to module events. Returns `true` when the event is fully
/// consumed host-side and must **not** be forwarded to the Dart ring.
pub(crate) fn on_module_event(event_type: &str, payload: &[u8]) -> bool {
    match event_type {
        EVT_TUN_RELEASED => {
            let fd = serde_json::from_slice::<serde_json::Value>(payload)
                .ok()
                .and_then(|v| v.get("fd").and_then(|f| f.as_i64()))
                .map(|f| f as i32)
                .unwrap_or(-1);
            crate::jni_bridge::note_tun_released(fd);
            false
        }
        EVT_UID_QUERY => on_uid_query_event(payload),
        _ => false,
    }
}

/// Bounded, coalescing queue drained by a single worker thread.
struct UidWorker {
    queue: Mutex<VecDeque<UidQueryHost>>,
    signal: Condvar,
    dropped: AtomicU64,
    coalesced: AtomicU64,
}

impl UidWorker {
    fn new() -> Self {
        Self {
            queue: Mutex::new(VecDeque::new()),
            signal: Condvar::new(),
            dropped: AtomicU64::new(0),
            coalesced: AtomicU64::new(0),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, VecDeque<UidQueryHost>> {
        self.queue.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Non-blocking enqueue. Coalesces a duplicate `recordId`, then evicts the
    /// oldest entry if the queue is at capacity. Never waits on the worker.
    fn enqueue(&self, query: UidQueryHost) {
        let mut queue = self.lock();
        if let Some(pos) = queue.iter().position(|q| q.record_id == query.record_id) {
            queue.remove(pos);
            self.coalesced.fetch_add(1, Ordering::SeqCst);
        }
        if queue.len() >= UID_QUERY_QUEUE_CAP {
            queue.pop_front();
            self.dropped.fetch_add(1, Ordering::SeqCst);
        }
        queue.push_back(query);
        drop(queue);
        self.signal.notify_all();
    }

    /// Take the next batch of at most [`UID_BATCH_MAX`]; never blocks.
    fn take_batch(&self) -> Vec<UidQueryHost> {
        let mut queue = self.lock();
        let n = queue.len().min(UID_BATCH_MAX);
        queue.drain(..n).collect()
    }

    /// Block until at least one query is queued (single worker only).
    #[cfg(not(test))]
    fn wait_for_work(&self) {
        let mut queue = self.lock();
        while queue.is_empty() {
            queue = self
                .signal
                .wait(queue)
                .unwrap_or_else(|e| e.into_inner());
        }
    }
}

static UID_WORKER: OnceLock<UidWorker> = OnceLock::new();

fn uid_worker() -> &'static UidWorker {
    UID_WORKER.get_or_init(UidWorker::new)
}

/// Parse a `{"queries":[...]}` payload and enqueue each well-formed query.
/// Any payload (even malformed) is consumed: it is an internal host event.
fn on_uid_query_event(payload: &[u8]) -> bool {
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(payload) {
        if let Some(queries) = value.get("queries").and_then(|q| q.as_array()) {
            for item in queries {
                if let Ok(query) = serde_json::from_value::<UidQueryHost>(item.clone()) {
                    uid_worker().enqueue(query);
                }
            }
        }
    }
    ensure_worker();
    true
}

/// Resolve a batch and broadcast the `uid.result` reply down to the modules.
/// A missing VM/service degrades to all-`unknown` inside `resolve_uids`.
fn resolve_and_reply(batch: &[UidQueryHost]) {
    if batch.is_empty() {
        return;
    }
    let answers = crate::jni_bridge::resolve_uids(batch);
    let Ok(bytes) = serde_json::to_vec(&serde_json::json!({ "results": answers })) else {
        return;
    };
    ModuleManager::global().broadcast_event(EVT_UID_RESULT, &bytes);
}

/// Spawn the single drain worker once, on the first query. Tests drive the
/// batch synchronously ([`drain_uid_batch_for_tests`]) so no thread races them.
#[cfg(not(test))]
fn ensure_worker() {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let spawned = std::thread::Builder::new()
            .name("gstore-uid-worker".to_string())
            .spawn(worker_loop);
        if spawned.is_err() {
            crate::log_bridge::push_host_log(
                3,
                "tun_bridge: failed to spawn uid worker".to_string(),
            );
        }
    });
}

#[cfg(test)]
fn ensure_worker() {}

#[cfg(not(test))]
fn worker_loop() {
    let worker = uid_worker();
    loop {
        worker.wait_for_work();
        let batch = worker.take_batch();
        resolve_and_reply(&batch);
    }
}

/// Test-only: clear the queue and counters.
#[cfg(test)]
pub(crate) fn reset_uid_worker_for_tests() {
    let worker = uid_worker();
    worker.lock().clear();
    worker.dropped.store(0, Ordering::SeqCst);
    worker.coalesced.store(0, Ordering::SeqCst);
}

/// Test-only: enqueue without starting the worker.
#[cfg(test)]
pub(crate) fn enqueue_uid_query_for_tests(query: UidQueryHost) {
    uid_worker().enqueue(query);
}

/// Test-only: current queue depth.
#[cfg(test)]
pub(crate) fn uid_queue_len_for_tests() -> usize {
    uid_worker().lock().len()
}

/// Test-only: number of entries evicted for capacity.
#[cfg(test)]
pub(crate) fn uid_dropped_for_tests() -> u64 {
    uid_worker().dropped.load(Ordering::SeqCst)
}

/// Test-only: number of duplicate `recordId`s coalesced.
#[cfg(test)]
pub(crate) fn uid_coalesced_for_tests() -> u64 {
    uid_worker().coalesced.load(Ordering::SeqCst)
}

/// Test-only: synchronously drain one batch, resolve+reply, return the ids.
#[cfg(test)]
pub(crate) fn drain_uid_batch_for_tests() -> Vec<u64> {
    let batch = uid_worker().take_batch();
    let ids = batch.iter().map(|q| q.record_id).collect();
    resolve_and_reply(&batch);
    ids
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

/// Host consumption of the internal `proxy.uid.query` event. The module asks the
/// host to attribute a captured TCP flow to an owning Android app; the host must
/// (a) swallow the event (never forward it to the Dart ring), (b) resolve it off
/// the emitting thread via a **bounded single worker**, and (c) reply with a
/// `uid.result` down-event once the batch is resolved.
///
/// ## Why a worker + queue
///
/// `host_emit_event` runs on the module's emit path; a JNI round-trip
/// (`ConnectivityManager.getConnectionOwnerUid`) must never block it. The queue
/// absorbs bursts; the worker drains serially so the JNI lane sees at most one
/// batch at a time.
///
/// ## Queue semantics (pinned)
///
/// * Bounded by [`UID_QUERY_QUEUE_CAP`].
/// * Enqueue is **non-blocking** and never waits on the worker.
/// * On overflow the **oldest** entry is dropped (`dropped` counter grows).
/// * A duplicate `recordId` is **coalesced** (the older copy is replaced), so a
///   hot flow cannot fill the queue with copies of itself.
/// * The worker drains at most [`UID_BATCH_MAX`] per `resolve_uids` call.
///
/// ## Reply routing
///
/// The answer is broadcast as `on_event{kind:"uid.result"}` via
/// [`ModuleManager::broadcast_event`]. Only the `proxy` module consumes it
/// (`on_event_impl` matches `"uid.result"`); every other module's `on_event`
/// either uses the trait default no-op or matches specific kinds and ignores an
/// unknown one (`gstore_mod_analyzer` logs and ignores). Broadcasting is
/// therefore behaviourally targeted and matches the existing `vpn.stop` lane.
#[cfg(test)]
mod uid_worker_tests {
    use super::*;
    use crate::jni_bridge::UidQueryHost;
    use crate::manager::GStoreModule;
    use gstore_contract::error::ModuleError;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use crate::TEST_SERIAL as TEST_LOCK;

    fn query(record_id: u64) -> UidQueryHost {
        UidQueryHost {
            record_id,
            protocol: "tcp".to_string(),
            src_ip: "10.10.0.2".to_string(),
            src_port: 40_000,
            dst_ip: "93.184.216.34".to_string(),
            dst_port: 443,
        }
    }

    /// `proxy.uid.query` is consumed (host-owned); `proxy.tun.released` keeps its
    /// existing pass-through behaviour so the Dart ring still sees it.
    #[test]
    fn uid_query_is_consumed_tun_released_is_not() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        assert!(
            on_module_event(EVT_UID_QUERY, br#"{"queries":[]}"#),
            "proxy.uid.query must be consumed by the host"
        );
        assert!(
            !on_module_event(EVT_TUN_RELEASED, br#"{"fd":1}"#),
            "proxy.tun.released keeps flowing to Dart"
        );
        assert!(!on_module_event("proxy.state", b"{}"));
    }

    /// Overflow is non-blocking, drops the oldest and coalesces duplicate ids.
    #[test]
    fn full_queue_drops_oldest_and_coalesces_without_blocking() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_uid_worker_for_tests();
        for i in 0..UID_QUERY_QUEUE_CAP as u64 {
            enqueue_uid_query_for_tests(query(i));
        }
        assert_eq!(uid_queue_len_for_tests(), UID_QUERY_QUEUE_CAP);
        assert_eq!(uid_dropped_for_tests(), 0);

        let started = Instant::now();
        enqueue_uid_query_for_tests(query(UID_QUERY_QUEUE_CAP as u64));
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "enqueue must never block the emitting thread"
        );
        assert_eq!(
            uid_queue_len_for_tests(),
            UID_QUERY_QUEUE_CAP,
            "queue stays bounded on overflow"
        );
        assert_eq!(uid_dropped_for_tests(), 1, "the oldest entry is dropped");

        // A duplicate recordId (now the back-most entry) is coalesced, not added.
        enqueue_uid_query_for_tests(query(UID_QUERY_QUEUE_CAP as u64));
        assert_eq!(uid_coalesced_for_tests(), 1, "duplicate recordId coalesced");
        assert_eq!(uid_dropped_for_tests(), 1, "coalescing adds no drop");
        assert_eq!(uid_queue_len_for_tests(), UID_QUERY_QUEUE_CAP);
    }

    /// A single drain resolves at most [`UID_BATCH_MAX`]; the rest waits its turn.
    #[test]
    fn batch_drain_is_capped_at_64_and_serial() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_uid_worker_for_tests();
        let total = UID_BATCH_MAX as u64 + 3;
        for i in 0..total {
            enqueue_uid_query_for_tests(query(i));
        }
        let first = drain_uid_batch_for_tests();
        assert_eq!(first.len(), UID_BATCH_MAX, "one batch resolves at most 64");
        assert_eq!(first[0], 0, "oldest first");
        assert_eq!(drain_uid_batch_for_tests().len(), 3, "the rest drains serially");
        assert!(drain_uid_batch_for_tests().is_empty(), "empty queue drains nothing");
    }

    /// external-integration_failure: no `JavaVM` on the test host => the whole
    /// batch backfills `unknown` and a single `uid.result` is broadcast.
    #[test]
    fn no_vm_batch_backfills_all_unknown() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        crate::jni_bridge::clear_impl();
        reset_uid_worker_for_tests();
        let rec = Arc::new(UidResultRecorder::default());
        let mgr = crate::manager::ModuleManager::global();
        let id = mgr.register(rec.clone());
        for i in 0..3u64 {
            enqueue_uid_query_for_tests(query(i));
        }
        assert_eq!(drain_uid_batch_for_tests().len(), 3, "no VM still drains (no panic)");

        let events = rec.events.lock().unwrap_or_else(|e| e.into_inner());
        let (kind, data) = events.last().expect("uid.result must be broadcast");
        assert_eq!(kind, EVT_UID_RESULT);
        let v: serde_json::Value = serde_json::from_slice(data).unwrap();
        let results = v["results"].as_array().expect("results array");
        assert_eq!(results.len(), 3);
        assert!(
            results.iter().all(|r| r["uid"].is_null()),
            "no VM => every answer is unknown"
        );
        drop(events);
        mgr.unref(id);
    }

    /// Adversarial race: concurrent enqueue + drain must not deadlock and the
    /// queue must stay bounded.
    #[test]
    fn concurrent_enqueue_and_drain_do_not_deadlock() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_uid_worker_for_tests();
        let producer = std::thread::spawn(|| {
            for i in 0..2_000u64 {
                enqueue_uid_query_for_tests(query(i));
            }
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let drained = drain_uid_batch_for_tests();
            if producer.is_finished() && drained.is_empty() {
                break;
            }
            assert!(Instant::now() < deadline, "enqueue/drain deadlocked");
            std::thread::yield_now();
        }
        producer.join().unwrap();
        assert!(uid_queue_len_for_tests() <= UID_QUERY_QUEUE_CAP, "queue bounded");
    }

    /// Fake `proxy` module: captures every down-event so the host `uid.result`
    /// reply can be asserted by kind and payload.
    #[derive(Default)]
    struct UidResultRecorder {
        events: Mutex<Vec<(String, Vec<u8>)>>,
    }

    impl GStoreModule for UidResultRecorder {
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
            _payload: &[u8],
        ) -> Result<Vec<u8>, ModuleError> {
            Err(ModuleError::method_not_found(method))
        }
        fn on_event(
            &self,
            _module_id: u64,
            kind: &str,
            data: &[u8],
        ) -> Result<(), ModuleError> {
            self.events
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push((kind.to_string(), data.to_vec()));
            Ok(())
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }
}
