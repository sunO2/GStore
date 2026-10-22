//! Notification + foreground-service host over the Kotlin `NotificationBridge`.
//!
//! Kotlin owns channel creation, permission checks and `NotificationManager`
//! posting; this module owns the pure contract: stable JSON payloads, the
//! per-notification 500 ms throttle, and foreground start/stop idempotency.
//! Every failure is typed; nothing panics across the JNI boundary.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use gstore_core::ports::platform::Notification;
use gstore_core::Error;
use jni::objects::{GlobalRef, JObject, JString, JValue};
use jni::JNIEnv;
use serde_json::{json, Value};

use crate::jni_bridge::{platform_context, platform_jvm};

/// Progress notification channel id (shared with the legacy Dart path).
pub const DOWNLOAD_CHANNEL_ID: &str = "download_progress";
/// Foreground-service notification channel id.
pub const FOREGROUND_CHANNEL_ID: &str = "foreground_service";
/// Stable foreground-service notification id.
pub const FOREGROUND_NOTIFICATION_ID: i32 = 997;
/// Minimum interval between two progress posts for the same notification id.
pub const NOTIFICATION_THROTTLE_MS: i64 = 500;

const NOTIFICATION_CLASS_NAME: &str = "com/suno2/gstore/NotificationBridge";
const NOTIFY_SIG: &str = "(Ljava/lang/String;)Ljava/lang/String;";
const START_FOREGROUND_SIG: &str = "(ILjava/lang/String;)Ljava/lang/String;";
const STOP_FOREGROUND_SIG: &str = "()Ljava/lang/String;";
const NOT_INITIALIZED: &str = "CORE_E_PLATFORM_NOT_INITIALIZED";
const PERMISSION_DENIED: &str = "CORE_E_NOTIFY_PERMISSION_DENIED";
const BRIDGE_ERROR: &str = "CORE_E_NOTIFY_BRIDGE";

/// Injectable monotonic-enough millisecond clock (tests use a fake).
pub type ClockFn = Arc<dyn Fn() -> i64 + Send + Sync>;

/// Current wall-clock milliseconds, saturating at 0 before the epoch.
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis() as i64)
}

/// JNI seam used by [`HostNotificationSink`]; tests script it without a device.
pub trait NotificationJni: Send + Sync {
    /// Posts one notification payload; returns the Kotlin JSON response.
    fn notify(&self, payload: &str) -> Result<String, String>;
    /// Starts the foreground service with one notification payload.
    fn start_foreground(&self, notification_id: i32, payload: &str) -> Result<String, String>;
    /// Stops the foreground service.
    fn stop_foreground(&self) -> Result<String, String>;
}

/// Cached `NotificationBridge` class, resolved on the app thread during init.
static NOTIFICATION_CLASS: OnceLock<GlobalRef> = OnceLock::new();

/// Caches the Kotlin bridge class exactly once (called from the app thread so
/// later Rust threads do not depend on the app class loader).
pub(crate) fn init_class(env: &mut JNIEnv) {
    if NOTIFICATION_CLASS.get().is_some() {
        return;
    }
    match env.find_class(NOTIFICATION_CLASS_NAME) {
        Ok(class) => match env.new_global_ref(&class) {
            Ok(global) => {
                let _ = NOTIFICATION_CLASS.set(global);
            }
            Err(error) => {
                let _ = env.exception_clear();
                crate::log_bridge::push_host_log(
                    3,
                    format!("NotificationBridge: 类 GlobalRef 失败: {error}"),
                );
            }
        },
        Err(error) => {
            let _ = env.exception_clear();
            crate::log_bridge::push_host_log(
                2,
                format!("NotificationBridge: 类未加载，稍后重试 find_class: {error}"),
            );
        }
    }
}

fn clear_exception(env: &mut JNIEnv) {
    if env.exception_check().unwrap_or(false) {
        env.exception_clear().ok();
    }
}

fn describe_exception(env: &mut JNIEnv) -> String {
    let Ok(throwable) = env.exception_occurred() else {
        return String::new();
    };
    env.exception_clear().ok();
    let throwable = JObject::from(throwable);
    let Ok(value) = env.call_method(&throwable, "toString", "()Ljava/lang/String;", &[]) else {
        clear_exception(env);
        return String::new();
    };
    let Ok(object) = value.l() else {
        return String::new();
    };
    if object.is_null() {
        return String::new();
    }
    let text: JString = object.into();
    env.get_string(&text)
        .map(std::convert::Into::into)
        .unwrap_or_default()
}

fn notification_class(env: &mut JNIEnv) -> Result<&'static GlobalRef, String> {
    if let Some(cached) = NOTIFICATION_CLASS.get() {
        return Ok(cached);
    }
    let class = match env.find_class(NOTIFICATION_CLASS_NAME) {
        Ok(class) => class,
        Err(error) => {
            let detail = describe_exception(env);
            clear_exception(env);
            let message = if detail.is_empty() {
                error.to_string()
            } else {
                detail
            };
            return Err(format!(
                "{BRIDGE_ERROR}: find {NOTIFICATION_CLASS_NAME}: {message}"
            ));
        }
    };
    let global = env
        .new_global_ref(&class)
        .map_err(|error| format!("{BRIDGE_ERROR}: cache {NOTIFICATION_CLASS_NAME}: {error}"))?;
    let _ = NOTIFICATION_CLASS.set(global);
    NOTIFICATION_CLASS
        .get()
        .ok_or_else(|| format!("{BRIDGE_ERROR}: cache {NOTIFICATION_CLASS_NAME}"))
}

/// Real bridge: calls the Kotlin `com.suno2.gstore.NotificationBridge` statics.
#[derive(Debug, Clone, Copy, Default)]
pub struct JniNotificationBridge;

impl JniNotificationBridge {
    /// Creates the bridge.
    pub const fn new() -> Self {
        Self
    }

    fn with_env<T>(
        operation: &str,
        body: impl FnOnce(&mut JNIEnv, &GlobalRef) -> Result<T, String>,
    ) -> Result<T, String> {
        if platform_context().is_none() {
            return Err(NOT_INITIALIZED.to_string());
        }
        let jvm = platform_jvm().ok_or_else(|| NOT_INITIALIZED.to_string())?;
        let mut env = jvm
            .attach_current_thread()
            .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: JNI attach: {error}"))?;
        let result = notification_class(&mut env).and_then(|class| body(&mut env, class));
        clear_exception(&mut env);
        result
    }

    fn jstring_value(env: &mut JNIEnv, object: JObject) -> Result<Option<String>, String> {
        if object.is_null() {
            return Ok(None);
        }
        let text: JString = object.into();
        env.get_string(&text)
            .map(|value| Some(value.into()))
            .map_err(|error| format!("{BRIDGE_ERROR}: JNI string: {error}"))
    }
}

impl NotificationJni for JniNotificationBridge {
    fn notify(&self, payload: &str) -> Result<String, String> {
        Self::with_env("notify", |env, class| {
            let argument = env
                .new_string(payload)
                .map_err(|error| format!("{BRIDGE_ERROR}: notify: argument: {error}"))?;
            let argument = JObject::from(argument);
            let value = env
                .call_static_method(class, "notify", NOTIFY_SIG, &[JValue::Object(&argument)])
                .map_err(|error| format!("{BRIDGE_ERROR}: notify: {error}"))?;
            let object = value
                .l()
                .map_err(|error| format!("{BRIDGE_ERROR}: notify: JNI value: {error}"))?;
            Self::jstring_value(env, object)?
                .ok_or_else(|| format!("{BRIDGE_ERROR}: notify returned null"))
        })
    }

    fn start_foreground(&self, notification_id: i32, payload: &str) -> Result<String, String> {
        Self::with_env("startForeground", |env, class| {
            let argument = env
                .new_string(payload)
                .map_err(|error| format!("{BRIDGE_ERROR}: startForeground: argument: {error}"))?;
            let argument = JObject::from(argument);
            let value = env
                .call_static_method(
                    class,
                    "startForeground",
                    START_FOREGROUND_SIG,
                    &[JValue::Int(notification_id), JValue::Object(&argument)],
                )
                .map_err(|error| format!("{BRIDGE_ERROR}: startForeground: {error}"))?;
            let object = value
                .l()
                .map_err(|error| format!("{BRIDGE_ERROR}: startForeground: JNI value: {error}"))?;
            Self::jstring_value(env, object)?
                .ok_or_else(|| format!("{BRIDGE_ERROR}: startForeground returned null"))
        })
    }

    fn stop_foreground(&self) -> Result<String, String> {
        Self::with_env("stopForeground", |env, class| {
            let value = env
                .call_static_method(class, "stopForeground", STOP_FOREGROUND_SIG, &[])
                .map_err(|error| format!("{BRIDGE_ERROR}: stopForeground: {error}"))?;
            let object = value
                .l()
                .map_err(|error| format!("{BRIDGE_ERROR}: stopForeground: JNI value: {error}"))?;
            Self::jstring_value(env, object)?
                .ok_or_else(|| format!("{BRIDGE_ERROR}: stopForeground returned null"))
        })
    }
}

/// Pure stable payload shared by notifications and the foreground service.
#[must_use]
pub fn notification_payload(notification: &Notification) -> Value {
    json!({
        "id": notification.id,
        "channelId": notification.channel_id,
        "title": notification.title,
        "body": notification.body,
        "progress": notification.progress,
        "ongoing": notification.ongoing,
        "payload": notification.payload,
    })
}

fn map_bridge_error(operation: &str, error: String) -> Error {
    if error.contains(NOT_INITIALIZED) {
        Error::Unsupported(NOT_INITIALIZED.to_string())
    } else {
        Error::Internal(format!("{BRIDGE_ERROR}: {operation}: {error}"))
    }
}

fn interpret_response(operation: &str, raw: &str) -> Result<(), Error> {
    let parsed: Value = serde_json::from_str(raw).map_err(|error| {
        Error::Internal(format!("{BRIDGE_ERROR}: {operation}: malformed: {error}"))
    })?;
    match parsed.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(()),
        Some(false) => {
            let code = parsed
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("CORE_E_NOTIFY_FAILED");
            if code.starts_with(PERMISSION_DENIED) {
                Err(Error::Forbidden(format!(
                    "{PERMISSION_DENIED}: {operation}"
                )))
            } else {
                Err(Error::Internal(format!(
                    "{BRIDGE_ERROR}: {operation}: {code}"
                )))
            }
        }
        None => Err(Error::Internal(format!(
            "{BRIDGE_ERROR}: {operation}: missing ok"
        ))),
    }
}

/// Notification sink with a per-id throttle and idempotent foreground state.
pub struct HostNotificationSink<B: NotificationJni = JniNotificationBridge> {
    bridge: B,
    clock: ClockFn,
    last_posted: Mutex<BTreeMap<i32, i64>>,
    foreground_running: AtomicBool,
}

impl<B: NotificationJni> HostNotificationSink<B> {
    /// Wraps a bridge with the real clock.
    pub fn new(bridge: B) -> Self {
        Self::with_clock(bridge, Arc::new(now_ms))
    }

    /// Wraps a bridge with an injectable clock.
    pub fn with_clock(bridge: B, clock: ClockFn) -> Self {
        Self {
            bridge,
            clock,
            last_posted: Mutex::new(BTreeMap::new()),
            foreground_running: AtomicBool::new(false),
        }
    }

    /// Whether the foreground service is currently started through this sink.
    pub fn foreground_running(&self) -> bool {
        self.foreground_running.load(Ordering::SeqCst)
    }

    /// Posts one notification, throttled per notification id.
    ///
    /// # Errors
    /// [`Error::Forbidden`] when notifications are denied, [`Error::Unsupported`]
    /// when the platform bridge is not initialized, [`Error::Internal`] for any
    /// other bridge failure.
    pub fn notify(&self, notification: &Notification) -> Result<(), Error> {
        let now = (self.clock)();
        {
            let last = self
                .last_posted
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if last
                .get(&notification.id)
                .is_some_and(|previous| now.saturating_sub(*previous) < NOTIFICATION_THROTTLE_MS)
            {
                return Ok(());
            }
        }
        let payload = notification_payload(notification).to_string();
        let raw = self
            .bridge
            .notify(&payload)
            .map_err(|error| map_bridge_error("notify", error))?;
        interpret_response("notify", &raw)?;
        self.last_posted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(notification.id, now);
        Ok(())
    }

    /// Starts the foreground service once; repeated calls are no-ops.
    ///
    /// # Errors
    /// Same mapping as [`HostNotificationSink::notify`].
    pub fn start_foreground(&self, notification: &Notification) -> Result<(), Error> {
        if self
            .foreground_running
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(());
        }
        let foreground = Notification {
            id: FOREGROUND_NOTIFICATION_ID,
            channel_id: FOREGROUND_CHANNEL_ID.to_string(),
            ongoing: true,
            ..notification.clone()
        };
        let payload = notification_payload(&foreground).to_string();
        let result = self
            .bridge
            .start_foreground(FOREGROUND_NOTIFICATION_ID, &payload)
            .map_err(|error| map_bridge_error("startForeground", error))
            .and_then(|raw| interpret_response("startForeground", &raw));
        if result.is_err() {
            self.foreground_running.store(false, Ordering::SeqCst);
        }
        result
    }

    /// Stops the foreground service once; repeated calls are no-ops.
    ///
    /// # Errors
    /// Same mapping as [`HostNotificationSink::notify`].
    pub fn stop_foreground(&self) -> Result<(), Error> {
        if !self.foreground_running.swap(false, Ordering::SeqCst) {
            return Ok(());
        }
        let result = self
            .bridge
            .stop_foreground()
            .map_err(|error| map_bridge_error("stopForeground", error))
            .and_then(|raw| interpret_response("stopForeground", &raw));
        if result.is_err() {
            self.foreground_running.store(true, Ordering::SeqCst);
        }
        result
    }
}

/// Process-global sink shared by [`crate::platform_host::AndroidPlatformHost`].
pub fn host_notification_sink() -> &'static HostNotificationSink {
    static SINK: OnceLock<HostNotificationSink> = OnceLock::new();
    SINK.get_or_init(|| HostNotificationSink::new(JniNotificationBridge))
}
