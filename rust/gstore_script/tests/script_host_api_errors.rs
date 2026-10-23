//! Typed failure paths: argument errors throw, host errors/panics degrade to
//! envelopes.

mod support;

use gstore_script::CODE_INVALID_ARGUMENT;
use serde_json::json;

use support::{fake_host, runtime};

#[test]
fn script_host_api_invalid_json_argument_throws_typed_error() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let invalid = runtime
        .eval(r#"sendMessage('host.config.get', '{bad')"#)
        .expect_err("invalid JSON must throw");
    assert_eq!(invalid.code(), CODE_INVALID_ARGUMENT, "{invalid}");

    let scalar = runtime
        .eval("sendMessage('host.config.get', 42)")
        .expect_err("non-object payload must throw");
    assert_eq!(scalar.code(), CODE_INVALID_ARGUMENT, "{scalar}");

    // The runtime stays usable after an argument error.
    assert_eq!(runtime.eval("1 + 1").expect("usable"), json!(2));
}

#[test]
fn script_host_api_host_error_becomes_envelope() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval("host.config.get('error')")
        .expect("host error must not throw");
    assert_eq!(
        out,
        json!({ "ok": false, "error": "CORE_E_SCRIPT_HOST: config refused" })
    );
    println!("host error envelope: {out}");
}

// NOTE: proves the **unwind profile only** (`gstore_script` tests run with the
// default `panic = "unwind"`). Release consumers (`gstore_host`/`gstore_core`)
// use `panic = "abort"`, so a production host panic aborts instead of producing
// this envelope. The assertion is kept, not weakened, and the distinction is
// documented in the README host implementer contract.
#[test]
fn script_host_api_host_panic_becomes_typed_envelope() {
    let (host, _calls) = fake_host();
    let runtime = runtime("js.a", host);

    let out = runtime
        .eval("host.config.get('panic')")
        .expect("host panic must not unwind through QuickJS");
    assert_eq!(out["ok"], json!(false));
    let error = out["error"].as_str().expect("error string");
    assert!(error.starts_with("CORE_E_SCRIPT_HOST:"), "{error}");
    assert!(error.contains("panicked"), "{error}");
    println!("host panic envelope: {out}");

    assert_eq!(
        runtime.eval("1 + 1").expect("runtime survives host panic"),
        json!(2)
    );
}
