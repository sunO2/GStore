//! Native bridge + JS prelude installation.
//!
//! `__gstoreSendMessage(method, payloadJson)` is a plain QuickJS function: it
//! returns the envelope as a JSON string and **never throws** for host failures.
//! The JS prelude (`prelude.js`) owns argument validation and the `host.*`
//! facade, so the Dart/Lua-style contract is defined in JavaScript where both
//! runtimes can be compared line by line.

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
) -> Result<(), ScriptError> {
    install_bridge(ctx, host, channel)?;
    ctx.eval::<Value, _>(PRELUDE)
        .map(|_| ())
        .map_err(|err| map_error(ctx, err, interrupt, timeout))
}

fn install_bridge(
    ctx: &Ctx<'_>,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
) -> Result<(), ScriptError> {
    let bridge = Function::new(
        ctx.clone(),
        move |method: String, payload: String| -> rquickjs::Result<String> {
            let payload: JsonValue = serde_json::from_str(&payload).unwrap_or(JsonValue::Null);
            Ok(envelope_json(host.as_ref(), &channel, &method, &payload))
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
) -> String {
    let result = catch_unwind(AssertUnwindSafe(|| {
        host.send_message(channel, method, payload)
    }));
    let envelope = match result {
        Ok(Ok(envelope)) => envelope,
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
