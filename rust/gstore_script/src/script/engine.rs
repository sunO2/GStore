//! QuickJS engine wiring: one runtime + context per channel, thread-confined.
//!
//! Everything in this module is created **inside** the channel thread, so
//! `rquickjs::Runtime`/`Context` never need to cross a thread boundary. Values
//! leave the thread only as `serde_json::Value` (or as typed errors), which is
//! what keeps the public API `Send`.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::time::Duration;

use rquickjs::{Coerced, Context, Ctx, Function, Promise, Runtime, Value};
use serde_json::Value as JsonValue;

use super::error::{ScriptError, CODE_HOST};
use super::host::ScriptHost;
use super::interrupt::InterruptState;
use super::options::ScriptOptions;

/// Native bridge installed as `globalThis.__gstoreSendMessage(method, payloadJson)`.
const BRIDGE_FN: &str = "__gstoreSendMessage";

/// Minimal prelude: exposes `sendMessage(method, payload)` to scripts while the
/// richer `host.*` surface stays Todo 2's job.
const PRELUDE: &str = r#"
(function () {
  'use strict';
  var bridge = globalThis.__gstoreSendMessage;
  function sendMessage(method, payload) {
    var payloadJson = JSON.stringify(payload === undefined ? null : payload);
    var envelope = JSON.parse(bridge(String(method), payloadJson));
    if (!envelope || envelope.ok !== true) {
      throw new Error(envelope && envelope.message
        ? envelope.message
        : 'CORE_E_SCRIPT_HOST: host call failed');
    }
    return envelope.data;
  }
  Object.defineProperty(globalThis, 'sendMessage', {
    value: sendMessage,
    writable: false,
    enumerable: false,
    configurable: false
  });
})();
"#;

/// A thread-confined QuickJS runtime.
pub(crate) struct Engine {
    // Declared before the context so the runtime outlives it on drop.
    _runtime: Runtime,
    ctx: Context,
    interrupt: Arc<InterruptState>,
    host: Arc<dyn ScriptHost>,
    eval_timeout: Duration,
}

impl Engine {
    pub(crate) fn new(
        options: &ScriptOptions,
        host: Arc<dyn ScriptHost>,
    ) -> Result<Self, ScriptError> {
        let runtime = Runtime::new()
            .map_err(|err| ScriptError::internal(format!("create QuickJS runtime: {err}")))?;
        runtime.set_memory_limit(options.memory_limit_bytes);
        runtime.set_max_stack_size(options.stack_limit_bytes);

        let interrupt = Arc::new(InterruptState::new());
        let handler_state = Arc::clone(&interrupt);
        runtime.set_interrupt_handler(Some(Box::new(move || handler_state.on_interrupt())));

        let ctx = Context::full(&runtime)
            .map_err(|err| ScriptError::internal(format!("create QuickJS context: {err}")))?;

        let bridge_host = Arc::clone(&host);
        ctx.with(|ctx| -> Result<(), ScriptError> {
            install_bridge(&ctx, bridge_host)?;
            ctx.eval::<Value, _>(PRELUDE)
                .map(|_| ())
                .map_err(|err| map_error(&ctx, err, &interrupt, options.eval_timeout))
        })?;

        Ok(Self {
            _runtime: runtime,
            ctx,
            interrupt,
            host,
            eval_timeout: options.eval_timeout,
        })
    }

    /// Evaluate `source` and return its JSON-serialisable completion value.
    ///
    /// A Promise completion value is drained (microtasks only) until settled,
    /// mirroring the Dart runtime's `call`/`evaluate` behaviour.
    pub(crate) fn eval(&self, source: &str) -> Result<JsonValue, ScriptError> {
        self.interrupt.arm(self.eval_timeout);
        let outcome = self.ctx.with(|ctx| self.eval_in_ctx(&ctx, source));
        self.interrupt.disarm();
        outcome
    }

    /// Invoke the registered host callback on the runtime thread.
    ///
    /// Used both by the Rust-facing `ScriptRuntime::send_message` and by the JS
    /// bridge. Panics are contained here rather than crossing an FFI frame.
    pub(crate) fn send_message(
        &self,
        method: &str,
        payload: &JsonValue,
    ) -> Result<JsonValue, ScriptError> {
        if method.trim().is_empty() {
            return Err(ScriptError::invalid_argument(
                "sendMessage method must not be empty",
            ));
        }
        match catch_unwind(AssertUnwindSafe(|| self.host.send_message(method, payload))) {
            Ok(result) => result,
            Err(_) => Err(ScriptError::host(format!(
                "host callback for `{method}` panicked"
            ))),
        }
    }

    fn eval_in_ctx<'js>(&self, ctx: &Ctx<'js>, source: &str) -> Result<JsonValue, ScriptError> {
        let value: Value<'js> = ctx
            .eval(source.to_owned())
            .map_err(|err| map_error(ctx, err, &self.interrupt, self.eval_timeout))?;

        let value = match value.try_into_promise() {
            Ok(promise) => self.await_promise(ctx, &promise)?,
            Err(plain) => plain,
        };

        let json = ctx
            .json_stringify(&value)
            .map_err(|err| map_error(ctx, err, &self.interrupt, self.eval_timeout))?;
        match json {
            Some(text) => {
                let text = text.to_string().map_err(|err| {
                    ScriptError::internal(format!("decode engine JSON string: {err}"))
                })?;
                serde_json::from_str(&text).map_err(|err| {
                    ScriptError::internal(format!("engine produced invalid JSON: {err}"))
                })
            }
            // undefined / function / symbol: JSON has no representation.
            None => Ok(JsonValue::Null),
        }
    }

    fn await_promise<'js>(
        &self,
        ctx: &Ctx<'js>,
        promise: &Promise<'js>,
    ) -> Result<Value<'js>, ScriptError> {
        loop {
            if let Some(result) = promise.result::<Value<'js>>() {
                return match result {
                    Ok(value) => Ok(value),
                    Err(err) => Err(map_error(ctx, err, &self.interrupt, self.eval_timeout)),
                };
            }
            if self.interrupt.fired() || self.interrupt.expired() {
                return Err(ScriptError::timeout(timeout_ms(self.eval_timeout)));
            }
            if !ctx.execute_pending_job() {
                // No queued job: a real async source (timer / host I/O) would need
                // an event loop, which is out of scope until the host API lands.
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }
}

/// Install the native `__gstoreSendMessage` bridge and the `sendMessage` prelude.
fn install_bridge(ctx: &Ctx<'_>, host: Arc<dyn ScriptHost>) -> Result<(), ScriptError> {
    let bridge = Function::new(
        ctx.clone(),
        move |method: String, payload: String| -> rquickjs::Result<String> {
            let payload: JsonValue = serde_json::from_str(&payload).unwrap_or(JsonValue::Null);
            let envelope =
                match catch_unwind(AssertUnwindSafe(|| host.send_message(&method, &payload))) {
                    Ok(Ok(data)) => serde_json::json!({ "ok": true, "data": data }),
                    Ok(Err(err)) => serde_json::json!({
                        "ok": false,
                        "code": err.code(),
                        "message": err.to_string(),
                    }),
                    Err(_) => serde_json::json!({
                        "ok": false,
                        "code": CODE_HOST,
                        "message": format!("{CODE_HOST}: host callback for `{method}` panicked"),
                    }),
                };
            Ok(serde_json::to_string(&envelope)
                .unwrap_or_else(|_| format!(r#"{{"ok":false,"code":"{CODE_HOST}"}}"#)))
        },
    )
    .map_err(|err| ScriptError::internal(format!("create host bridge: {err}")))?;

    ctx.globals()
        .set(BRIDGE_FN, bridge)
        .map_err(|err| ScriptError::internal(format!("install host bridge: {err}")))
}

/// Convert an `rquickjs` failure into a typed error without leaking its lifetime.
fn map_error(
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
    if lowered.contains("out of memory") || lowered.contains("stack overflow") {
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

fn timeout_ms(timeout: Duration) -> u64 {
    u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX)
}
