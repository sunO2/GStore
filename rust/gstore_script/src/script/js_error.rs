//! Mapping `rquickjs` failures to typed `CORE_E_SCRIPT_*` errors.

use std::time::Duration;

use rquickjs::{Coerced, Ctx};

use super::error::ScriptError;
use super::interrupt::InterruptState;

/// Convert an `rquickjs` failure into a typed error without leaking its lifetime.
pub(crate) fn map_error(
    ctx: &Ctx<'_>,
    err: rquickjs::Error,
    interrupt: &InterruptState,
    timeout: Duration,
) -> ScriptError {
    if interrupt.fired() {
        return ScriptError::timeout(timeout_ms(timeout));
    }
    if matches!(err, rquickjs::Error::Allocation) {
        return ScriptError::limit("QuickJS allocation failed (memory limit)");
    }
    let message = if matches!(err, rquickjs::Error::Exception) {
        exception_message(ctx)
    } else {
        err.to_string()
    };
    let lowered = message.to_ascii_lowercase();
    if lowered.contains("out of memory")
        || lowered.contains("stack overflow")
        || lowered.contains("call stack")
    {
        return ScriptError::limit(message);
    }
    ScriptError::from_js_message(message)
}

/// Best-effort message from the pending JS exception (consumes it).
fn exception_message(ctx: &Ctx<'_>) -> String {
    let value = ctx.catch();
    if value.is_uncatchable_error() {
        return "interrupted".to_owned();
    }
    if let Some(object) = value.as_object() {
        if let Ok(Coerced(message)) = object.get::<_, Coerced<String>>("message") {
            return message;
        }
    }
    if let Some(text) = value.as_string() {
        if let Ok(text) = text.to_string() {
            return text;
        }
    }
    "JavaScript exception".to_owned()
}

pub(crate) fn timeout_ms(timeout: Duration) -> u64 {
    u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX)
}
