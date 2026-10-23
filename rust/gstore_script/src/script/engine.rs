//! QuickJS engine wiring: one runtime + context per channel, thread-confined.
//!
//! Everything in this module is created **inside** the channel thread, so
//! `rquickjs::Runtime`/`Context` never need to cross a thread boundary. Values
//! leave the thread only as `serde_json::Value` (or as typed errors), which is
//! what keeps the public API `Send`.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::time::Duration;

use rquickjs::{Context, Ctx, Promise, Runtime, Value};
use serde_json::Value as JsonValue;

use super::bridge;
use super::channel::ScriptChannel;
use super::error::ScriptError;
use super::host::ScriptHost;
use super::interrupt::InterruptState;
use super::js_error::{map_error, timeout_ms};
use super::options::ScriptOptions;

/// A thread-confined QuickJS runtime.
pub(crate) struct Engine {
    // Declared before the context so the runtime outlives it on drop.
    _runtime: Runtime,
    ctx: Context,
    interrupt: Arc<InterruptState>,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
    eval_timeout: Duration,
}

impl Engine {
    pub(crate) fn new(
        options: &ScriptOptions,
        host: Arc<dyn ScriptHost>,
        channel: ScriptChannel,
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

        ctx.with(|ctx| {
            bridge::install(
                &ctx,
                Arc::clone(&host),
                channel.clone(),
                &interrupt,
                options.eval_timeout,
            )
        })?;

        Ok(Self {
            _runtime: runtime,
            ctx,
            interrupt,
            host,
            channel,
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

    /// Invoke the registered host callback on the runtime thread with channel
    /// affinity. Used by the JS bridge and by `ScriptRuntime::send_message`.
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
        let channel = &self.channel;
        match catch_unwind(AssertUnwindSafe(|| {
            self.host.send_message(channel, method, payload)
        })) {
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
