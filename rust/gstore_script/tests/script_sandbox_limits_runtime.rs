//! Sandbox limits, part 2: wall-clock, memory/stack, global budget, legacy.
//!
//! Tiny overridden budgets keep the suite in the seconds range; `TEST_GUARD`
//! serialises every test because the live-runtime cap is process-wide.

use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use gstore_script::{
    HttpRequest, HttpResponse, NativeCallRequest, SandboxLimits, ScriptChannel, ScriptError,
    ScriptErrorKind, ScriptHost, ScriptOptions, ScriptRuntime, CODE_INVALID_ARGUMENT, CODE_LIMIT,
    CODE_TIMEOUT,
};
use serde_json::{json, Value as JsonValue};

const FAST: Duration = Duration::from_millis(2_000);
const BUDGET: Duration = Duration::from_millis(50);

static TEST_GUARD: Mutex<()> = Mutex::new(());

fn guard() -> MutexGuard<'static, ()> {
    TEST_GUARD.lock().unwrap_or_else(|error| error.into_inner())
}

fn limits() -> SandboxLimits {
    SandboxLimits::default()
        .with_eval_timeout(FAST)
        .with_long_eval_timeout(FAST)
}

fn spawn(name: &str, limits: SandboxLimits) -> ScriptRuntime {
    let channel = ScriptChannel::new(name).expect("valid channel key");
    ScriptRuntime::spawn(
        channel,
        ScriptOptions::new(limits),
        std::sync::Arc::new(SandboxHost),
    )
    .expect("runtime spawns")
}

fn spawn_error(name: &str, limits: SandboxLimits) -> ScriptError {
    let channel = ScriptChannel::new(name).expect("valid channel key");
    match ScriptRuntime::spawn(
        channel,
        ScriptOptions::new(limits),
        std::sync::Arc::new(SandboxHost),
    ) {
        Ok(runtime) => {
            runtime.dispose().expect("dispose unexpected runtime");
            panic!("spawn should have failed closed");
        }
        Err(error) => error,
    }
}

struct SandboxHost;

impl ScriptHost for SandboxHost {
    fn http(
        &self,
        _channel: &ScriptChannel,
        _request: HttpRequest,
    ) -> Result<HttpResponse, ScriptError> {
        Ok(HttpResponse::new(200, json!({"ok": true})))
    }

    fn native_call(
        &self,
        _channel: &ScriptChannel,
        _request: NativeCallRequest,
    ) -> Result<Option<JsonValue>, ScriptError> {
        Ok(None)
    }
}

fn assert_limit(error: &ScriptError) {
    assert_eq!(error.kind(), ScriptErrorKind::Limit, "{error}");
    assert_eq!(error.code(), CODE_LIMIT, "{error}");
}

#[test]
fn script_sandbox_limits_memory_bomb_is_typed() {
    let _guard = guard();
    let runtime = spawn(
        "sandbox.memory",
        limits().with_memory_limit(2 * 1024 * 1024),
    );

    let error = runtime
        .eval("'x'.repeat(8 * 1024 * 1024)")
        .expect_err("memory bomb must hit the heap ceiling");
    assert_limit(&error);
    println!("memory bomb: {error}");
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_deep_recursion_is_typed() {
    let _guard = guard();
    let runtime = spawn("sandbox.stack", limits().with_stack_limit(256 * 1024));

    let error = runtime
        .eval("function f() { return f(); } f()")
        .expect_err("deep recursion must hit the stack ceiling");
    assert_limit(&error);
    println!("deep recursion: {error}");
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_eval_and_long_budgets_both_timing_out() {
    let _guard = guard();
    let runtime = spawn(
        "sandbox.timeout",
        limits()
            .with_eval_timeout(BUDGET)
            .with_long_eval_timeout(BUDGET),
    );

    for (label, outcome) in [
        ("eval", runtime.eval("while (true) {}")),
        ("eval_long", runtime.eval_long("while (true) {}")),
    ] {
        let started = Instant::now();
        let error = outcome.expect_err("infinite loop must be interrupted");
        assert_eq!(error.kind(), ScriptErrorKind::Timeout, "{label}: {error}");
        assert_eq!(error.code(), CODE_TIMEOUT, "{label}: {error}");
        assert!(started.elapsed() < Duration::from_secs(1));
        println!("{label} budget: {error}");
    }
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_concurrent_runtime_cap_is_typed() {
    let _guard = guard();
    let options = limits().with_max_concurrent_runtimes(1);
    let first = spawn("sandbox.live.1", options.clone());

    let error = spawn_error("sandbox.live.2", options.clone());
    assert_limit(&error);
    println!("live-runtime cap: {error}");

    first.dispose().expect("clean dispose");
    let third = spawn("sandbox.live.3", options);
    third.dispose().expect("slot released");
}

#[test]
fn script_sandbox_limits_cumulative_budget_is_typed() {
    let _guard = guard();
    let options = limits()
        .with_eval_timeout(FAST)
        .with_cumulative_eval_budget(BUDGET);
    let runtime = spawn("sandbox.cumulative", options);

    let error = runtime
        .eval("while (true) {}")
        .expect_err("cumulative cap interrupts the call");
    assert_limit(&error);
    println!("cumulative cap: {error}");

    let after = runtime
        .eval("1 + 1")
        .expect_err("no further eval after the budget is gone");
    assert_limit(&after);
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_zero_disabling_values_are_rejected() {
    let _guard = guard();
    for (name, bad) in [
        ("memory", SandboxLimits::default().with_memory_limit(0)),
        ("stack", SandboxLimits::default().with_stack_limit(0)),
        ("output", SandboxLimits::default().with_max_output(0)),
        ("response", SandboxLimits::default().with_max_response(0)),
        (
            "eval",
            SandboxLimits::default().with_eval_timeout(Duration::ZERO),
        ),
        (
            "cumulative",
            SandboxLimits::default().with_cumulative_eval_budget(Duration::ZERO),
        ),
    ] {
        let error = spawn_error("sandbox.zero", bad);
        assert_eq!(error.code(), CODE_INVALID_ARGUMENT, "{name}: {error}");
    }
    println!("zero limits rejected");
}

#[test]
fn script_sandbox_limits_unknown_utils_and_ui_are_explicit() {
    let _guard = guard();
    let runtime = spawn("sandbox.legacy", limits());

    let utils = runtime
        .eval("host.utils.call('nope', {})")
        .expect("unknown utils method is an envelope");
    assert_eq!(
        utils,
        json!({"ok": false, "error": "host.utils.nope 未注册"})
    );
    println!("unknown utils: {utils}");

    let ui = runtime
        .eval("host.ui.call('nope', {})")
        .expect("unknown ui method is an envelope");
    assert_eq!(
        ui,
        json!({"ok": false, "error": "host.native.ui.nope 未注册"})
    );
    println!("unknown ui: {ui}");
    runtime.dispose().expect("clean dispose");
}
