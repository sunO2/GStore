//! QuickJS engine wiring: one runtime + context per channel, thread-confined.
//!
//! Everything in this module is created **inside** the channel thread, so
//! `rquickjs::Runtime`/`Context` never need to cross a thread boundary. Values
//! leave the thread only as `serde_json::Value` (or as typed errors), which is
//! what keeps the public API `Send`.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rquickjs::{Context, Ctx, Promise, Runtime, Value};
use serde_json::Value as JsonValue;

use super::bridge;
use super::channel::ScriptChannel;
use super::error::ScriptError;
use super::host::ScriptHost;
use super::interrupt::InterruptState;
use super::js_error::{map_error, timeout_ms};
use super::limits::SandboxLimits;
use super::options::ScriptOptions;

/// A thread-confined QuickJS runtime.
pub(crate) struct Engine {
    // Declared before the context so the runtime outlives it on drop.
    _runtime: Runtime,
    ctx: Context,
    interrupt: Arc<InterruptState>,
    host: Arc<dyn ScriptHost>,
    channel: ScriptChannel,
    limits: SandboxLimits,
    spent_eval: Duration,
    cumulative_exhausted: bool,
}

impl Engine {
    pub(crate) fn new(
        options: &ScriptOptions,
        host: Arc<dyn ScriptHost>,
        channel: ScriptChannel,
    ) -> Result<Self, ScriptError> {
        let limits = options.limits.clone();
        let runtime = Runtime::new()
            .map_err(|err| ScriptError::internal(format!("create QuickJS runtime: {err}")))?;
        runtime.set_memory_limit(limits.memory_limit_bytes);
        runtime.set_max_stack_size(limits.stack_limit_bytes);

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
                limits.eval_timeout,
                &limits,
            )
        })?;

        Ok(Self {
            _runtime: runtime,
            ctx,
            interrupt,
            host,
            channel,
            limits,
            spent_eval: Duration::ZERO,
            cumulative_exhausted: false,
        })
    }

    /// Evaluate `source` under the normal wall-clock budget.
    pub(crate) fn eval(&mut self, source: &str) -> Result<JsonValue, ScriptError> {
        let budget = self.limits.eval_timeout;
        self.eval_with_budget(source, budget)
    }

    /// Evaluate `source` under the long-operation budget (30 s by default).
    pub(crate) fn eval_long(&mut self, source: &str) -> Result<JsonValue, ScriptError> {
        let budget = self.limits.long_eval_timeout;
        self.eval_with_budget(source, budget)
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
        let limits = &self.limits;
        match catch_unwind(AssertUnwindSafe(|| {
            self.host.send_message(channel, method, payload, limits)
        })) {
            Ok(Ok(envelope)) => {
                bridge::enforce_response_limit(method, envelope, limits.max_response_bytes)
            }
            Ok(Err(err)) => Err(err),
            Err(_) => Err(ScriptError::host(format!(
                "host callback for `{method}` panicked"
            ))),
        }
    }

    fn eval_with_budget(
        &mut self,
        source: &str,
        requested: Duration,
    ) -> Result<JsonValue, ScriptError> {
        let effective = self.begin_budget(requested)?;
        let started = Instant::now();
        let outcome = self
            .ctx
            .with(|ctx| self.eval_in_ctx(&ctx, source, effective));
        self.interrupt.disarm();
        self.spent_eval = self.spent_eval.saturating_add(started.elapsed());
        match outcome {
            // A timeout caused by the cumulative cap (rather than by the call's
            // own budget) is a budget breach, not a normal slow call.
            Err(error)
                if error.kind() == super::ScriptErrorKind::Timeout && effective < requested =>
            {
                self.cumulative_exhausted = true;
                Err(self.exhausted_error())
            }
            other => other,
        }
    }

    fn exhausted_error(&self) -> ScriptError {
        ScriptError::limit(format!(
            "cumulative eval budget of {} ms exhausted",
            timeout_ms(self.limits.cumulative_eval_budget)
        ))
    }

    fn begin_budget(&mut self, requested: Duration) -> Result<Duration, ScriptError> {
        let remaining = self
            .limits
            .cumulative_eval_budget
            .saturating_sub(self.spent_eval);
        if self.cumulative_exhausted || remaining.is_zero() {
            self.cumulative_exhausted = true;
            return Err(self.exhausted_error());
        }
        let effective = requested.min(remaining);
        self.interrupt.arm(effective);
        Ok(effective)
    }

    fn eval_in_ctx<'js>(
        &self,
        ctx: &Ctx<'js>,
        source: &str,
        budget: Duration,
    ) -> Result<JsonValue, ScriptError> {
        let value: Value<'js> = ctx
            .eval(source.to_owned())
            .map_err(|err| map_error(ctx, err, &self.interrupt, budget))?;

        let value = match value.try_into_promise() {
            Ok(promise) => self.await_promise(ctx, &promise, budget)?,
            Err(plain) => plain,
        };

        let json = ctx
            .json_stringify(&value)
            .map_err(|err| map_error(ctx, err, &self.interrupt, budget))?;
        match json {
            Some(text) => {
                let text = text.to_string().map_err(|err| {
                    ScriptError::internal(format!("decode engine JSON string: {err}"))
                })?;
                if text.len() > self.limits.max_output_bytes {
                    return Err(ScriptError::limit(format!(
                        "script output is {} bytes, limit is {}",
                        text.len(),
                        self.limits.max_output_bytes
                    )));
                }
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
        budget: Duration,
    ) -> Result<Value<'js>, ScriptError> {
        loop {
            if let Some(result) = promise.result::<Value<'js>>() {
                return match result {
                    Ok(value) => Ok(value),
                    Err(err) => Err(map_error(ctx, err, &self.interrupt, budget)),
                };
            }
            if self.interrupt.fired() || self.interrupt.expired() {
                return Err(ScriptError::timeout(timeout_ms(budget)));
            }
            if !ctx.execute_pending_job() {
                // No queued job: a real async source (timer / host I/O) would need
                // an event loop, which is out of scope until the host API lands.
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }
}
