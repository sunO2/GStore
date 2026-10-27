//! Failure-path coverage for Todo 1: a runaway script must be interrupted by the
//! wall-clock budget, never hang the suite, and surface a typed timeout error.

use std::sync::Arc;
use std::time::{Duration, Instant};

use gstore_script::{
    ScriptChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions, ScriptRuntime,
    CODE_TIMEOUT,
};
use serde_json::Value;

/// Small budget: the point is that it fires quickly, not that it matches prod.
const BUDGET_MS: u64 = 80;
const CI_DEADLINE: Duration = Duration::from_secs(3);

#[derive(Debug, Default)]
struct NoHost;

impl ScriptHost for NoHost {
    fn send_message(
        &self,
        _channel: &ScriptChannel,
        method: &str,
        _payload: &Value,
        _limits: &gstore_script::SandboxLimits,
    ) -> Result<Value, ScriptError> {
        Err(ScriptError::host(format!(
            "unexpected host call `{method}`"
        )))
    }
}

fn runtime_with_budget() -> ScriptRuntime {
    let channel = ScriptChannel::new("test.timeout").expect("valid channel key");
    let options = ScriptOptions::default().with_eval_timeout(Duration::from_millis(BUDGET_MS));
    ScriptRuntime::spawn(channel, options, Arc::new(NoHost)).expect("runtime spawns")
}

#[test]
fn script_runtime_eval_infinite_loop_times_out() {
    let runtime = runtime_with_budget();

    let started = Instant::now();
    let err = runtime
        .eval("while (true) {}")
        .expect_err("infinite loop must be interrupted");
    let elapsed = started.elapsed();

    assert_eq!(err.kind(), ScriptErrorKind::Timeout, "{err}");
    assert_eq!(err.code(), CODE_TIMEOUT);
    assert!(
        err.to_string().contains("CORE_E_SCRIPT_TIMEOUT"),
        "unexpected message: {err}"
    );
    assert!(
        elapsed < CI_DEADLINE,
        "interrupt took {elapsed:?}, suite would hang CI"
    );

    runtime.dispose().expect("runtime disposes after a timeout");
}

#[test]
fn script_runtime_eval_recovers_after_timeout() {
    let runtime = runtime_with_budget();
    let err = runtime.eval("while (true) {}").expect_err("times out");
    assert_eq!(err.kind(), ScriptErrorKind::Timeout);
    assert_eq!(
        runtime.eval("1 + 1").expect("recovers after interrupt"),
        serde_json::json!(2)
    );
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_eval_promise_that_never_settles_times_out() {
    let runtime = runtime_with_budget();

    let started = Instant::now();
    let err = runtime
        .eval("new Promise(function () {})")
        .expect_err("unsettled promise must hit the wall-clock budget");
    let elapsed = started.elapsed();

    assert_eq!(err.kind(), ScriptErrorKind::Timeout, "{err}");
    assert!(
        elapsed < CI_DEADLINE,
        "promise drain took {elapsed:?}, suite would hang CI"
    );

    runtime.dispose().expect("runtime disposes after a timeout");
}
