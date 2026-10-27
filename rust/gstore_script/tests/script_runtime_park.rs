//! Host park accounting: a parked wait is exempt from the eval deadline and the
//! cumulative eval clock, and the remaining budget is charged after unpark.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use gstore_script::{
    SandboxLimits, ScriptChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions,
    ScriptRuntime, CODE_LIMIT, CODE_TIMEOUT,
};
use serde_json::{json, Value};

const PARK_BOUND: Duration = Duration::from_millis(500);

struct ParkHost;

impl ScriptHost for ParkHost {
    fn send_message(
        &self,
        _channel: &ScriptChannel,
        method: &str,
        payload: &Value,
        _limits: &SandboxLimits,
    ) -> Result<Value, ScriptError> {
        let millis = payload["ms"].as_u64().unwrap_or(0);
        let bound = payload["bound"]
            .as_u64()
            .map_or(PARK_BOUND, Duration::from_millis);
        match method {
            "test.burn" => {
                thread::sleep(Duration::from_millis(millis));
                Ok(json!({ "ok": true, "data": millis }))
            }
            "test.park" => {
                let guard = ScriptRuntime::begin_park(bound);
                thread::sleep(Duration::from_millis(millis));
                drop(guard);
                Ok(json!({ "ok": true, "data": millis }))
            }
            "test.park_panic" => {
                let _guard = ScriptRuntime::begin_park(bound);
                thread::sleep(Duration::from_millis(millis));
                panic!("parked host panicked on purpose");
            }
            other => Err(ScriptError::host(format!("unknown method `{other}`"))),
        }
    }
}

fn spawn(name: &str, limits: SandboxLimits) -> ScriptRuntime {
    let channel = ScriptChannel::new(name).expect("valid channel key");
    ScriptRuntime::spawn(channel, ScriptOptions::new(limits), Arc::new(ParkHost))
        .expect("runtime spawns")
}

#[test]
fn script_runtime_park_exempts_the_normal_eval_deadline() {
    let limits = SandboxLimits::default()
        .with_eval_timeout(Duration::from_millis(120))
        .with_long_eval_timeout(Duration::from_millis(120));
    let runtime = spawn("park.deadline", limits);

    let started = Instant::now();
    let parked = runtime
        .eval(
            "sendMessage('test.park', {ms: 300}); \
             var t = Date.now(); while (Date.now() - t < 60) {} 'unparked'",
        )
        .expect("a 300 ms park and 60 ms of JS must outlive the 120 ms eval deadline");
    let parked_for = started.elapsed();
    println!(
        "[park-deadline] eval_timeout=120ms park=300ms js=60ms elapsed={}ms result={parked}",
        parked_for.as_millis()
    );
    assert!(parked_for >= Duration::from_millis(280), "{parked_for:?}");
    assert_eq!(parked, json!("unparked"));

    let error = runtime
        .eval("while (true) {}")
        .expect_err("the eval deadline must be armed again after unpark");
    assert_eq!(error.kind(), ScriptErrorKind::Timeout, "{error}");
    assert_eq!(error.code(), CODE_TIMEOUT, "{error}");

    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_park_pauses_cumulative_budget_instead_of_resetting_it() {
    const CUMULATIVE_MS: u64 = 400;
    const BURN_MS: u64 = 150;
    const PARK_MS: u64 = 280;
    const OVERSHOOT_MS: u64 = 320;

    let limits = SandboxLimits::default()
        .with_eval_timeout(Duration::from_secs(2))
        .with_long_eval_timeout(Duration::from_secs(2))
        .with_cumulative_eval_budget(Duration::from_millis(CUMULATIVE_MS));
    let runtime = spawn("park.cumulative", limits);

    let first = Instant::now();
    runtime
        .eval(&format!("sendMessage('test.burn', {{ms: {BURN_MS}}})"))
        .expect("first burn fits the cumulative budget");
    let first_spent = first.elapsed();
    let remaining = Duration::from_millis(CUMULATIVE_MS).saturating_sub(first_spent);
    println!(
        "[park-cumulative] budget={CUMULATIVE_MS}ms first_spent={}ms remaining={}ms",
        first_spent.as_millis(),
        remaining.as_millis()
    );
    assert!(
        remaining < Duration::from_millis(PARK_MS),
        "test premise: the park must be larger than the remaining budget"
    );

    let parked = runtime
        .eval(&format!("sendMessage('test.park', {{ms: {PARK_MS}}})"))
        .expect("a parked wait larger than the remaining budget must still complete");
    assert_eq!(parked["ok"], json!(true));
    println!("[park-cumulative] parked={PARK_MS}ms result={parked}");

    // If parking had reset the clock, the full 400 ms would be available and a
    // 320 ms burn would pass. The burn itself completes (a host sleep cannot be
    // interrupted), and the *next* eval proves only part of the budget remains.
    let started = Instant::now();
    let overshoot = runtime
        .eval(&format!("sendMessage('test.burn', {{ms: {OVERSHOOT_MS}}})"))
        .expect("the burn itself finishes; accounting happens after it");
    println!(
        "[park-cumulative] overshoot={OVERSHOOT_MS}ms elapsed={}ms result={overshoot}",
        started.elapsed().as_millis()
    );

    let error = runtime
        .eval("1 + 1")
        .expect_err("the remaining budget must be charged after unpark");
    println!("[park-cumulative] next_eval_error={error}");
    assert_eq!(error.kind(), ScriptErrorKind::Limit, "{error}");
    assert_eq!(error.code(), CODE_LIMIT, "{error}");

    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_park_is_clamped_to_its_bound() {
    let limits = SandboxLimits::default()
        .with_eval_timeout(Duration::from_millis(120))
        .with_cumulative_eval_budget(Duration::from_secs(5));
    let runtime = spawn("park.bound", limits);

    let started = Instant::now();
    let error = runtime
        .eval(
            "sendMessage('test.park', {ms: 250, bound: 40}); \
             var t = Date.now(); while (Date.now() - t < 50) {}",
        )
        .expect_err("only the 40 ms bound may be exempt, so the deadline still expires");
    println!(
        "[park-bound] park=250ms bound=40ms elapsed={}ms error={error}",
        started.elapsed().as_millis()
    );
    assert_eq!(error.kind(), ScriptErrorKind::Timeout, "{error}");
    assert_eq!(error.code(), CODE_TIMEOUT, "{error}");

    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_park_guard_survives_a_host_panic() {
    let limits = SandboxLimits::default()
        .with_eval_timeout(Duration::from_millis(500))
        .with_cumulative_eval_budget(Duration::from_secs(5));
    let runtime = spawn("park.panic", limits);

    let envelope = runtime
        .eval("sendMessage('test.park_panic', {ms: 50})")
        .expect("a host panic is contained as an envelope");
    println!("[park-panic] envelope={envelope}");
    assert_eq!(envelope["ok"], json!(false));
    assert_eq!(
        runtime
            .eval("2 + 2")
            .expect("runtime recovers after the panic"),
        json!(4)
    );

    runtime.dispose().expect("clean dispose");
}
