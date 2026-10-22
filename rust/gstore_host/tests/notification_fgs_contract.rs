//! Todo 5 contract: Rust-owned notifications and foreground service.
//!
//! Every test name contains `notification_fgs_contract` so the plan QA command
//! selects this binary. A scripted bridge and an injected clock keep the tests
//! deterministic: no device, no sleeps, no real JNI.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::ports::platform::{Capability, Notification, PlatformHost};
use gstore_core::Error;
use gstore_host::notification_host::{
    notification_payload, ClockFn, HostNotificationSink, NotificationJni, DOWNLOAD_CHANNEL_ID,
    FOREGROUND_CHANNEL_ID, FOREGROUND_NOTIFICATION_ID, NOTIFICATION_THROTTLE_MS,
};
use gstore_host::platform_host::AndroidPlatformHost;

#[derive(Debug, Clone, PartialEq, Eq)]
enum BridgeCall {
    Notify(String),
    StartForeground(i32, String),
    StopForeground,
}

#[derive(Default, Clone)]
struct RecordingBridge {
    calls: Arc<Mutex<Vec<BridgeCall>>>,
    notify_response: Arc<Mutex<Option<String>>>,
    start_response: Arc<Mutex<Option<String>>>,
    stop_response: Arc<Mutex<Option<String>>>,
}

impl RecordingBridge {
    fn calls(&self) -> Vec<BridgeCall> {
        self.calls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    fn notify_count(&self) -> usize {
        self.calls()
            .iter()
            .filter(|call| matches!(call, BridgeCall::Notify(_)))
            .count()
    }

    fn record(&self, call: BridgeCall) {
        self.calls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(call);
    }

    fn response(slot: &Arc<Mutex<Option<String>>>) -> Result<String, String> {
        Ok(slot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .unwrap_or_else(|| r#"{"ok":true}"#.to_string()))
    }
}

impl NotificationJni for RecordingBridge {
    fn notify(&self, payload: &str) -> Result<String, String> {
        self.record(BridgeCall::Notify(payload.to_string()));
        Self::response(&self.notify_response)
    }

    fn start_foreground(&self, notification_id: i32, payload: &str) -> Result<String, String> {
        self.record(BridgeCall::StartForeground(
            notification_id,
            payload.to_string(),
        ));
        Self::response(&self.start_response)
    }

    fn stop_foreground(&self) -> Result<String, String> {
        self.record(BridgeCall::StopForeground);
        Self::response(&self.stop_response)
    }
}

fn fake_clock() -> (Arc<AtomicI64>, ClockFn) {
    let now = Arc::new(AtomicI64::new(0));
    let handle = Arc::clone(&now);
    let clock: ClockFn = Arc::new(move || handle.load(Ordering::SeqCst));
    (now, clock)
}

fn notification(id: i32) -> Notification {
    Notification {
        id,
        channel_id: DOWNLOAD_CHANNEL_ID.to_string(),
        title: "下载任务".to_string(),
        body: "下载中 42%".to_string(),
        progress: Some(42),
        ongoing: false,
        payload: Some("download_center".to_string()),
    }
}

#[test]
fn notification_fgs_contract_throttles_per_id_at_500ms() {
    let (clock, clock_fn) = fake_clock();
    let bridge = RecordingBridge::default();
    let sink = HostNotificationSink::with_clock(bridge.clone(), clock_fn);

    clock.store(0, Ordering::SeqCst);
    sink.notify(&notification(1)).expect("first post");
    assert_eq!(bridge.notify_count(), 1);

    clock.store(NOTIFICATION_THROTTLE_MS - 1, Ordering::SeqCst);
    sink.notify(&notification(1)).expect("throttled post is Ok");
    assert_eq!(bridge.notify_count(), 1);

    clock.store(NOTIFICATION_THROTTLE_MS, Ordering::SeqCst);
    sink.notify(&notification(1)).expect("boundary post");
    assert_eq!(bridge.notify_count(), 2);

    sink.notify(&notification(2))
        .expect("other id is independent");
    assert_eq!(bridge.notify_count(), 3);
}

#[test]
fn notification_fgs_contract_permission_denied_is_typed() {
    let (_clock, clock_fn) = fake_clock();
    let bridge = RecordingBridge::default();
    *bridge
        .notify_response
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some(r#"{"ok":false,"code":"CORE_E_NOTIFY_PERMISSION_DENIED"}"#.to_string());
    let sink = HostNotificationSink::with_clock(bridge.clone(), clock_fn);

    let error = sink.notify(&notification(1)).expect_err("denied");
    assert!(matches!(error, Error::Forbidden(_)));
    assert!(error.message().contains("CORE_E_NOTIFY_PERMISSION_DENIED"));
}

#[test]
fn notification_fgs_contract_start_stop_are_idempotent() {
    let (_clock, clock_fn) = fake_clock();
    let bridge = RecordingBridge::default();
    let sink = HostNotificationSink::with_clock(bridge.clone(), clock_fn);

    sink.start_foreground(&notification(1)).expect("start");
    sink.start_foreground(&notification(1))
        .expect("second start");
    assert!(sink.foreground_running());
    assert_eq!(
        bridge
            .calls()
            .iter()
            .filter(|call| matches!(call, BridgeCall::StartForeground(_, _)))
            .count(),
        1
    );

    sink.stop_foreground().expect("stop");
    sink.stop_foreground().expect("second stop");
    assert!(!sink.foreground_running());
    assert_eq!(
        bridge
            .calls()
            .iter()
            .filter(|call| matches!(call, BridgeCall::StopForeground))
            .count(),
        1
    );
}

#[test]
fn notification_fgs_contract_payload_is_exact() {
    let (_clock, clock_fn) = fake_clock();
    let bridge = RecordingBridge::default();
    let sink = HostNotificationSink::with_clock(bridge.clone(), clock_fn);

    let payload = notification_payload(&notification(7));
    assert_eq!(payload["id"], 7);
    assert_eq!(payload["channelId"], DOWNLOAD_CHANNEL_ID);
    assert_eq!(payload["title"], "下载任务");
    assert_eq!(payload["body"], "下载中 42%");
    assert_eq!(payload["progress"], 42);
    assert_eq!(payload["ongoing"], false);
    assert_eq!(payload["payload"], "download_center");

    sink.start_foreground(&notification(7)).expect("start");
    let calls = bridge.calls();
    let start = calls
        .iter()
        .find_map(|call| match call {
            BridgeCall::StartForeground(id, payload) => Some((*id, payload)),
            _ => None,
        })
        .expect("start call");
    assert_eq!(start.0, FOREGROUND_NOTIFICATION_ID);
    let foreground: serde_json::Value = serde_json::from_str(start.1).expect("json");
    assert_eq!(foreground["id"], FOREGROUND_NOTIFICATION_ID);
    assert_eq!(foreground["channelId"], FOREGROUND_CHANNEL_ID);
    assert_eq!(foreground["ongoing"], false);
}

#[test]
fn notification_fgs_contract_android_host_capabilities() {
    let caps = AndroidPlatformHost::new().capabilities();
    for cap in [
        Capability::Inventory,
        Capability::DeviceInfo,
        Capability::Install,
        Capability::Uninstall,
        Capability::Launch,
        Capability::Notify,
        Capability::ForegroundService,
    ] {
        assert!(caps.supports(cap), "missing capability: {cap}");
    }
    for cap in [
        Capability::StoragePaths,
        Capability::Connectivity,
        Capability::Secrets,
    ] {
        assert!(!caps.supports(cap), "unexpected capability: {cap}");
    }
}
