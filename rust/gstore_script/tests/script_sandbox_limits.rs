//! Sandbox limits, part 1: defaults, output, response, redirects.
//!
//! Tiny overridden budgets keep the suite in the seconds range; `TEST_GUARD`
//! serialises every test because the live-runtime cap is process-wide.

use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use gstore_script::{
    HttpRequest, HttpResponse, NativeCallRequest, SandboxLimits, ScriptChannel, ScriptError,
    ScriptErrorKind, ScriptHost, ScriptOptions, ScriptRuntime, CODE_INVALID_ARGUMENT, CODE_LIMIT,
};
use serde_json::{json, Value as JsonValue};

const FAST: Duration = Duration::from_millis(2_000);

static TEST_GUARD: Mutex<()> = Mutex::new(());

pub(crate) fn guard() -> MutexGuard<'static, ()> {
    TEST_GUARD.lock().unwrap_or_else(|error| error.into_inner())
}

pub(crate) fn limits() -> SandboxLimits {
    SandboxLimits::default()
        .with_eval_timeout(FAST)
        .with_long_eval_timeout(FAST)
}

pub(crate) fn spawn(
    name: &str,
    limits: SandboxLimits,
    host: std::sync::Arc<dyn ScriptHost>,
) -> ScriptRuntime {
    let channel = ScriptChannel::new(name).expect("valid channel key");
    ScriptRuntime::spawn(channel, ScriptOptions::new(limits), host).expect("runtime spawns")
}

pub(crate) fn spawn_error(name: &str, limits: SandboxLimits) -> ScriptError {
    let channel = ScriptChannel::new(name).expect("valid channel key");
    match ScriptRuntime::spawn(
        channel,
        ScriptOptions::new(limits),
        std::sync::Arc::new(SandboxHost::default()),
    ) {
        Ok(runtime) => {
            runtime.dispose().expect("dispose unexpected runtime");
            panic!("spawn should have failed closed");
        }
        Err(error) => error,
    }
}

#[derive(Default)]
pub(crate) struct SandboxHost {
    pub(crate) redirects: Mutex<Vec<u32>>,
    pub(crate) response: Option<JsonValue>,
}

impl ScriptHost for SandboxHost {
    fn http(
        &self,
        _channel: &ScriptChannel,
        request: HttpRequest,
    ) -> Result<HttpResponse, ScriptError> {
        self.redirects
            .lock()
            .expect("redirect lock")
            .push(request.max_redirects);
        Ok(HttpResponse::new(
            200,
            self.response.clone().unwrap_or_else(|| json!({"ok": true})),
        ))
    }

    fn native_call(
        &self,
        _channel: &ScriptChannel,
        _request: NativeCallRequest,
    ) -> Result<Option<JsonValue>, ScriptError> {
        Ok(None)
    }
}

pub(crate) fn assert_limit(error: &ScriptError) {
    assert_eq!(error.kind(), ScriptErrorKind::Limit, "{error}");
    assert_eq!(error.code(), CODE_LIMIT, "{error}");
}

#[test]
fn script_sandbox_limits_defaults_match_the_plan() {
    let limits = SandboxLimits::default();
    assert_eq!(limits.memory_limit_bytes, 64 * 1024 * 1024);
    assert_eq!(limits.stack_limit_bytes, 1024 * 1024);
    assert_eq!(limits.eval_timeout, Duration::from_secs(5));
    assert_eq!(limits.long_eval_timeout, Duration::from_secs(30));
    assert_eq!(limits.max_output_bytes, 10 * 1024 * 1024);
    assert_eq!(limits.max_response_bytes, 20 * 1024 * 1024);
    assert_eq!(limits.max_redirects, 5);
    assert_eq!(limits.max_concurrent_runtimes, 32);
    assert_eq!(limits.cumulative_eval_budget, Duration::from_secs(600));
    println!("defaults: {limits:?}");
}

#[test]
fn script_sandbox_limits_output_over_cap_is_typed_not_truncated() {
    let _guard = guard();
    let runtime = spawn(
        "sandbox.output",
        limits().with_max_output(32),
        std::sync::Arc::new(SandboxHost::default()),
    );

    let error = runtime
        .eval("'x'.repeat(100)")
        .expect_err("oversized output must fail");
    assert_limit(&error);
    println!("oversized output: {error}");

    let ok = runtime
        .eval("'x'.repeat(10)")
        .expect("under the cap succeeds");
    assert_eq!(ok, json!("xxxxxxxxxx"));
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_response_over_cap_is_typed_without_data() {
    let _guard = guard();
    let host = std::sync::Arc::new(SandboxHost {
        response: Some(json!("y".repeat(200))),
        ..SandboxHost::default()
    });
    let runtime = spawn("sandbox.response", limits().with_max_response(64), host);

    let out = runtime
        .eval("host.network.get('https://example.test/ok')")
        .expect("a limit breach is an envelope, not a throw");
    assert_eq!(out["ok"], json!(false));
    assert!(
        out["error"]
            .as_str()
            .is_some_and(|text| text.starts_with(CODE_LIMIT)),
        "not a typed limit error: {out}"
    );
    assert!(out.get("data").is_none(), "no partial data: {out}");
    println!("oversized response: {out}");
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_redirects_are_clamped_to_the_policy() {
    let _guard = guard();
    let host = std::sync::Arc::new(SandboxHost::default());
    let runtime = spawn("sandbox.redirects", limits(), host.clone());

    runtime
        .eval("host.network.get('https://example.test/a', {maxRedirects: 99})")
        .expect("script cannot raise the cap");
    runtime
        .eval("host.network.get('https://example.test/b', {maxRedirects: 2})")
        .expect("script may tighten the cap");
    runtime
        .eval("host.network.get('https://example.test/c')")
        .expect("default hop count");
    assert_eq!(*host.redirects.lock().expect("redirects"), vec![5, 2, 5]);
    runtime.dispose().expect("clean dispose");

    let tightened = std::sync::Arc::new(SandboxHost::default());
    let runtime = spawn(
        "sandbox.redirects.tight",
        limits().with_max_redirects(2),
        tightened.clone(),
    );
    runtime
        .eval("host.network.get('https://example.test/d', {maxRedirects: 99})")
        .expect("host policy wins over the script");
    assert_eq!(*tightened.redirects.lock().expect("redirects"), vec![2]);
    runtime.dispose().expect("clean dispose");
}

#[test]
fn script_sandbox_limits_redirects_above_contract_are_rejected() {
    let _guard = guard();
    let error = spawn_error("sandbox.redirects.invalid", limits().with_max_redirects(9));
    assert_eq!(error.code(), CODE_INVALID_ARGUMENT, "{error}");
    println!("redirect policy rejected: {error}");
}
