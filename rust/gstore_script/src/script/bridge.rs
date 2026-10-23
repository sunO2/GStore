//! Native bridge + JS prelude installation.
//!
//! `__gstoreSendMessage(method, payloadJson)` is a plain QuickJS function: it
//! returns the envelope as a JSON string and **never throws** for host failures.
//! The JS prelude (`prelude.js`) owns argument validation and the `host.*`
//! facade, so the Dart/Lua-style contract is defined in JavaScript where both
//! runtimes can be compared line by line.
//!
//! Sandbox enforcement lives here for the script-facing path: a `host.network.*`
//! `data` larger than the response ceiling becomes a typed `CORE_E_SCRIPT_LIMIT`
//! envelope (never a truncated success), and the redirect policy is handed to
//! the dispatcher so a script cannot raise it.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::time::Duration;

use rquickjs::{Ctx, Function, Value};
use serde_json::{json, Value as JsonValue};

use super::channel::ScriptChannel;
use super::error::{ScriptError, CODE_HOST, CODE_INTERNAL};
use super::host::ScriptHost;
use super::interrupt::InterruptState;
use super::js_error::map_error;
use super::limits::SandboxLimits;

/// Bridge global (internal; the public surface is `sendMessage`).
const BRIDGE_FN: &str = "__gstoreSendMessage";

/// `host.*` facade + `sendMessage`, checked in as an asset rather than a Rust
/// string literal so parity with the Dart prefix is reviewable.
const PRELUDE: &str = include_str!("prelude.js");

/// Install the native bridge and evaluate the prelude before user code.
pub(crate) fn install(
    ctx: &Ctx<'_>,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
    interrupt: &Arc<InterruptState>,
    timeout: Duration,
    limits: &SandboxLimits,
) -> Result<(), ScriptError> {
    install_bridge(ctx, host, channel, limits)?;
    ctx.eval::<Value, _>(PRELUDE)
        .map(|_| ())
        .map_err(|err| map_error(ctx, err, interrupt, timeout))
}

fn install_bridge(
    ctx: &Ctx<'_>,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
    limits: &SandboxLimits,
) -> Result<(), ScriptError> {
    let limits = limits.clone();
    let bridge = Function::new(
        ctx.clone(),
        move |method: String, payload: String| -> rquickjs::Result<String> {
            let payload: JsonValue = serde_json::from_str(&payload).unwrap_or(JsonValue::Null);
            Ok(envelope_json(
                host.as_ref(),
                &channel,
                &method,
                &payload,
                &limits,
            ))
        },
    )
    .map_err(|err| ScriptError::internal(format!("create host bridge: {err}")))?;

    ctx.globals()
        .set(BRIDGE_FN, bridge)
        .map_err(|err| ScriptError::internal(format!("install host bridge: {err}")))
}

/// Run the dispatcher, contain panics, and serialise the envelope.
fn envelope_json(
    host: &dyn ScriptHost,
    channel: &ScriptChannel,
    method: &str,
    payload: &JsonValue,
    limits: &SandboxLimits,
) -> String {
    let result = catch_unwind(AssertUnwindSafe(|| {
        host.send_message(channel, method, payload, limits)
    }));
    let envelope = match result {
        Ok(Ok(envelope)) => enforce_response_limit(method, envelope, limits.max_response_bytes)
            .unwrap_or_else(|err| json!({ "ok": false, "error": err.to_string() })),
        // A host error degrades exactly like Dart (`{ok:false,error}`), never
        // as a thrown JS exception.
        Ok(Err(err)) => json!({ "ok": false, "error": err.to_string() }),
        Err(_) => json!({
            "ok": false,
            "error": format!("{CODE_HOST}: host callback for `{method}` panicked"),
        }),
    };
    serde_json::to_string(&envelope).unwrap_or_else(|_| {
        format!(r#"{{"ok":false,"error":"{CODE_INTERNAL}: serialise host envelope"}}"#)
    })
}

/// Reject an oversized `host.network.*` response body before it reaches JS.
///
/// Only `host.network.*` is capped: other capabilities (catalog rows, config)
/// are already bounded by their own producers and by the output ceiling. The
/// measurement is the serialised `data`, so a huge string and a huge object are
/// treated identically.
pub(crate) fn enforce_response_limit(
    method: &str,
    envelope: JsonValue,
    max_bytes: usize,
) -> Result<JsonValue, ScriptError> {
    if !method.starts_with("host.network.") {
        return Ok(envelope);
    }
    let Some(data) = envelope.get("data") else {
        return Ok(envelope);
    };
    let size = serde_json::to_vec(data).map_or(usize::MAX, |bytes| bytes.len());
    if size > max_bytes {
        return Err(ScriptError::limit(format!(
            "host response data is {size} bytes, limit is {max_bytes}"
        )));
    }
    Ok(envelope)
}
