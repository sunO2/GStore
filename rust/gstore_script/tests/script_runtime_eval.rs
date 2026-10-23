//! Happy-path coverage for Todo 1: eval, JSON mapping, the `sendMessage` bridge
//! and per-channel isolation.

use std::sync::Arc;
use std::time::Duration;

use gstore_script::{
    ScriptChannel, ScriptError, ScriptErrorKind, ScriptHost, ScriptOptions, ScriptRuntime,
    CODE_HOST,
};
use serde_json::{json, Value};

#[derive(Debug, Default)]
struct EchoHost;

impl ScriptHost for EchoHost {
    fn send_message(&self, method: &str, payload: &Value) -> Result<Value, ScriptError> {
        match method {
            "echo" => Ok(json!({ "method": method, "payload": payload })),
            "boom" => Err(ScriptError::host("host refused the call")),
            "panic" => panic!("host callback panicked on purpose"),
            other => Err(ScriptError::host(format!("unknown method `{other}`"))),
        }
    }
}

fn runtime_for(channel: &str) -> ScriptRuntime {
    let channel = ScriptChannel::new(channel).expect("valid channel key");
    let options = ScriptOptions::default().with_eval_timeout(Duration::from_millis(1_000));
    ScriptRuntime::spawn(channel, options, Arc::new(EchoHost)).expect("runtime spawns")
}

#[test]
fn script_runtime_eval_maps_js_values_to_json() {
    let runtime = runtime_for("test.eval");

    assert_eq!(
        runtime
            .eval("({answer: 42, ok: true, list: [1, 'two', null]})")
            .expect("object evaluates"),
        json!({"answer": 42, "ok": true, "list": [1, "two", null]})
    );
    assert_eq!(runtime.eval("1 + 1").expect("number evaluates"), json!(2));
    assert_eq!(
        runtime.eval("'hello'").expect("string evaluates"),
        json!("hello")
    );
    // undefined has no JSON representation; the contract is `null`, not an error.
    assert_eq!(
        runtime.eval("undefined").expect("undefined evaluates"),
        Value::Null
    );

    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_eval_reports_js_and_syntax_errors_as_eval() {
    let runtime = runtime_for("test.eval.errors");

    let thrown = runtime
        .eval("throw new Error('boom')")
        .expect_err("throw fails");
    assert_eq!(thrown.kind(), ScriptErrorKind::Eval);
    assert_eq!(thrown.code(), gstore_script::CODE_EVAL);
    assert!(thrown.to_string().contains("boom"), "{thrown}");

    let syntax = runtime.eval("function (").expect_err("syntax error fails");
    assert_eq!(syntax.kind(), ScriptErrorKind::Eval);

    // The runtime survives a failed evaluation.
    assert_eq!(runtime.eval("2 + 2").expect("recovers"), json!(4));
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_eval_drains_promises() {
    let runtime = runtime_for("test.eval.promise");
    assert_eq!(
        runtime
            .eval("Promise.resolve({value: 7})")
            .expect("promise evaluates"),
        json!({"value": 7})
    );
    let rejected = runtime
        .eval("Promise.reject(new Error('nope'))")
        .expect_err("rejected promise fails");
    assert_eq!(rejected.kind(), ScriptErrorKind::Eval);
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_eval_dispatches_send_message() {
    let runtime = runtime_for("test.host");

    let result = runtime
        .eval("sendMessage('echo', {appId: 'org.example'})")
        .expect("host call returns");
    assert_eq!(result["payload"]["appId"], json!("org.example"));

    let denied = runtime
        .eval("sendMessage('boom', null)")
        .expect_err("host error surfaces to JS");
    assert_eq!(denied.kind(), ScriptErrorKind::Host);
    assert_eq!(denied.code(), CODE_HOST);

    let panicked = runtime
        .eval("sendMessage('panic', null)")
        .expect_err("host panic becomes a typed error");
    assert_eq!(panicked.kind(), ScriptErrorKind::Host);

    // Rust-side dispatch uses the same host path and channel affinity.
    assert_eq!(
        runtime
            .send_message("echo", json!({"a": 1}))
            .expect("rust-side dispatch"),
        json!({"method": "echo", "payload": {"a": 1}})
    );

    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_runtime_eval_isolates_channels() {
    let first = runtime_for("test.channel.a");
    let second = runtime_for("test.channel.b");

    first.eval("globalThis.marker = 'a'").expect("sets marker");
    assert_eq!(
        first.eval("globalThis.marker").expect("reads marker"),
        json!("a")
    );
    assert_eq!(
        second.eval("typeof globalThis.marker").expect("isolated"),
        json!("undefined")
    );

    first.dispose().expect("dispose first");
    second.dispose().expect("dispose second");
}

#[test]
fn script_runtime_eval_rejects_empty_channel() {
    let err = ScriptChannel::new("   ").expect_err("blank key rejected");
    assert_eq!(err.kind(), ScriptErrorKind::InvalidArgument);
    assert_eq!(err.code(), gstore_script::CODE_INVALID_ARGUMENT);
}

#[test]
fn script_runtime_eval_maps_memory_exhaustion_to_limit() {
    let channel = ScriptChannel::new("test.limit").expect("valid channel key");
    let options = ScriptOptions::default()
        .with_eval_timeout(Duration::from_millis(1_000))
        .with_memory_limit(4 * 1024 * 1024);
    let runtime =
        ScriptRuntime::spawn(channel, options, Arc::new(EchoHost)).expect("runtime spawns");

    let err = runtime
        .eval("'x'.repeat(64 * 1024 * 1024)")
        .expect_err("memory limit must fail the evaluation");
    assert_eq!(err.kind(), ScriptErrorKind::Limit, "{err}");
    runtime.dispose().expect("clean dispose");
}
