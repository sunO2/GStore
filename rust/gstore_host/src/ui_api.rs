//! `script.ui_request` round-trip: emit, park, and deliver a UI answer.
//!
//! # Design
//!
//! A channel script calls `host.ui.call(method, payload)` (the JS prelude maps
//! it to `host.native.call {ns:"ui"}`). The host builds a
//! [`CoreEvent::ScriptUiRequest`](gstore_core::CoreEvent::ScriptUiRequest) with a
//! fresh `request_id`, publishes it on the existing module event bridge under
//! the wire name `script.ui_request`, and then **parks the script thread** on a
//! one-shot channel. `UiApi.respond(request_id, payload_json)` removes the
//! pending entry and wakes the parked thread with the parsed JSON value; the
//! script receives `{ok:true,data:<payload>}`. Unknown or already-expired ids
//! return a typed `CORE_E_SCRIPT_UI_UNKNOWN_REQUEST` error. The wait is bounded
//! by the configured UI budget (30 s by default): expiry removes the entry and
//! the script receives `{ok:false,error:"CORE_E_SCRIPT_TIMEOUT: ..."}` from the
//! bridge.
//!
//! # Event shape
//!
//! `kind` is the UI handler name (`showVersionPicker`, `showBuildHistory`, ...)
//! so the Dart lane can route on it directly. `title` is a human-readable label,
//! `message` carries the raw method payload as JSON (the 8 handlers take
//! structured maps, not form fields), and `fields` stays empty for them.
//!
//! # Parked wait vs. eval budgets
//!
//! The script runs under `ScriptRuntime::eval_long`, so the normal 5 s eval
//! deadline is not armed at all while the thread is parked. The long budget is
//! configured as `UI budget + 5 s`, which guarantees the UI timeout is produced
//! by this module before QuickJS interrupts the evaluation. The leaf crate's
//! cumulative eval clock still counts parked time (it measures wall-clock around
//! the whole eval); excluding it needs an engine-level park primitive. The host
//! reports that gap instead of faking an exemption (see `script_api.rs`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gstore_core::dto::ChannelKey;
use gstore_core::CoreEvent;
use gstore_script::{ScriptChannel, ScriptError};
use serde_json::Value as JsonValue;

/// Stable code returned by [`respond`] for unknown or expired request ids.
pub const UI_UNKNOWN_REQUEST: &str = "CORE_E_SCRIPT_UI_UNKNOWN_REQUEST";

/// UI handlers reachable through `host.ui.call` / `script.ui_request`.
pub const UI_METHODS: [&str; 8] = [
    "showVersionPicker",
    "showBuildHistory",
    "refreshDetail",
    "updateDownloadList",
    "showUAPicker",
    "updateDetail",
    "setBusy",
    "download",
];

/// Whether `method` is one of the eight UI handlers.
pub fn is_ui_method(method: &str) -> bool {
    UI_METHODS.contains(&method)
}

static PENDING: OnceLock<Mutex<HashMap<String, SyncSender<JsonValue>>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

fn pending() -> &'static Mutex<HashMap<String, SyncSender<JsonValue>>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_request_id() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let seq = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    format!("ui-{}-{millis}-{seq}", std::process::id())
}

fn ui_title(method: &str) -> &'static str {
    match method {
        "showVersionPicker" => "选择版本",
        "showBuildHistory" => "构建历史",
        "refreshDetail" => "刷新详情",
        "updateDownloadList" => "更新下载列表",
        "showUAPicker" => "选择 User-Agent",
        "updateDetail" => "更新详情",
        "setBusy" => "忙碌状态",
        "download" => "下载",
        _ => "脚本请求",
    }
}

/// Emit one `script.ui_request` event and park until the UI answers.
///
/// The event is queued on the module event bridge (ring buffer when Dart is not
/// subscribed), so it is observable by the Flutter lane and by tests. A host
/// error is returned as [`ScriptError::timeout`] on expiry; the dispatcher turns
/// it into the `CORE_E_SCRIPT_TIMEOUT` envelope the script sees.
pub fn request(
    channel: &ScriptChannel,
    app_id: Option<String>,
    method: &str,
    payload: &JsonValue,
    budget: Duration,
) -> Result<JsonValue, ScriptError> {
    let key = ChannelKey::new(channel.as_str())
        .map_err(|error| ScriptError::internal(format!("invalid script channel: {error}")))?;
    let request_id = next_request_id();
    let event = CoreEvent::ScriptUiRequest {
        key,
        app_id,
        request_id: request_id.clone(),
        kind: method.to_owned(),
        title: ui_title(method).to_owned(),
        message: Some(payload.to_string()),
        fields: Vec::new(),
    };
    let wire = event.wire_name();
    let body = event
        .to_json()
        .map_err(|error| ScriptError::internal(format!("serialise ui request: {error}")))?;

    let (tx, rx) = mpsc::sync_channel(1);
    {
        let mut guard = pending()
            .lock()
            .map_err(|_| ScriptError::internal("ui request registry poisoned"))?;
        guard.insert(request_id.clone(), tx);
    }
    crate::event_bridge::push_event(0, 0, wire, body.into_bytes());

    match rx.recv_timeout(budget) {
        Ok(value) => Ok(value),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            let _ = take_pending(&request_id);
            Err(ScriptError::internal(
                "ui response channel closed before a response arrived",
            ))
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            // A response may have landed in the same instant as the deadline.
            if let Ok(value) = rx.try_recv() {
                return Ok(value);
            }
            let _ = take_pending(&request_id);
            Err(ScriptError::timeout(
                u64::try_from(budget.as_millis()).unwrap_or(u64::MAX),
            ))
        }
    }
}

fn take_pending(request_id: &str) -> Option<SyncSender<JsonValue>> {
    pending()
        .lock()
        .ok()
        .and_then(|mut guard| guard.remove(request_id))
}

/// Delivers the UI answer for `request_id`.
///
/// `payload_json` is parsed as JSON (the UI returns the value the script's
/// `host.ui.call` resolves to; `null` is valid). Unknown, answered, or expired
/// ids are a typed error, never a panic and never a silent success.
pub fn respond(request_id: &str, payload_json: &str) -> Result<(), String> {
    let payload: JsonValue = serde_json::from_str(payload_json)
        .map_err(|error| format!("invalid_argument: ui response is not valid JSON: {error}"))?;
    let pending = take_pending(request_id).ok_or_else(|| {
        format!("{UI_UNKNOWN_REQUEST}: unknown or expired UI request id `{request_id}`")
    })?;
    pending.send(payload).map_err(|_| {
        format!("{UI_UNKNOWN_REQUEST}: UI request `{request_id}` is no longer being awaited")
    })
}

#[cfg(test)]
pub(crate) fn reset_for_tests() {
    if let Ok(mut guard) = pending().lock() {
        guard.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_request_id_is_typed_not_a_panic() {
        let error = respond("missing-id", "null").expect_err("unknown id must fail");
        assert!(error.starts_with(UI_UNKNOWN_REQUEST), "{error}");
    }

    #[test]
    fn invalid_response_json_is_rejected_before_any_wait() {
        let error = respond("whatever", "{not json").expect_err("invalid JSON must fail");
        assert!(error.starts_with("invalid_argument:"), "{error}");
    }
}
