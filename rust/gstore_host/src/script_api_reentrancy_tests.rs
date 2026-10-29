//! Todo 7 regression: a pack `jscall` that parks on `host.ui.call` must never
//! deadlock a re-entrant dispatch from the Dart UI handler.
//!
//! # Deadlock shape being locked
//!
//! A pack method's JS calls `host.ui.call('showVersionPicker', {})`. The host
//! pushes a `script.ui_request` event and parks the eval thread on the response
//! channel — all while [`ScriptEntry::run`](crate::script_runtime_entry::ScriptEntry)
//! still holds the per-entry `op` mutex. The Dart UI handler reacts to that event
//! and re-enters the same pack (`versionOptions`/`switchVersion`/`buildHistory`)
//! on a *different* FRB worker thread, which calls `run` again and blocks on the
//! `op` the parked eval already owns — a 30 s stall / wrong result.
//!
//! The guard under test is a precise per-entry `parked` flag: a re-entrant call
//! that arrives while the entry is parked is rejected **fast** with the typed
//! `CORE_E_SCRIPT_UI_REENTRANT` error, while the parked outer call still
//! completes once the UI answers. Legitimate contention (no park in flight) still
//! blocks normally.
//!
//! The typed code is asserted as a literal (not the `ui_api::UI_REENTRANT`
//! constant) so the tests compile and fail at *runtime* against the unguarded
//! code — a true red test — instead of merely failing to compile.

use std::time::{Duration, Instant};

use crate::script_api_test_support::{
    clear_ui_state, harness, spawn_responder, wait_for_ui_request, zip_with, Harness,
};
use crate::TEST_SERIAL;

/// Short UI budget so a regression that blocks on `op` fails fast instead of
/// stalling for the production 30 s.
const UI_BUDGET_MS: u64 = 400;
/// A re-entrant rejection must return in well under the UI budget; this bound is
/// half of it, so a block-the-whole-budget regression cannot pass.
const REENTRANT_FAST_MS: u64 = 200;

const KEY: &str = "js_reentrancy";
const TYPED_CODE: &str = "CORE_E_SCRIPT_UI_REENTRANT";

/// The outer (parking) method's JS: on `getAllApps` it calls `host.ui.call` and
/// returns whatever the UI answers.
const ENTRY_SCRIPT: &str = r#"
function main(method, params) {
  if (method === 'getAllApps') {
    var res = host.ui.call('showVersionPicker', {});
    return { ok: true, data: { ui: res } };
  }
  return { ok: true, data: { method: method } };
}
"#;

/// The detail script is never evaluated while parked (the guard returns before
/// `eval`), but the pack carries it so the re-entrant `versionOptions` dispatch
/// is otherwise well-formed.
const DETAIL_SCRIPT: &str = r#"
function main(method, params) {
  return { ok: true, data: { method: method } };
}
"#;

struct Roundtrip {
    outer: Result<String, String>,
    reentrant: Result<String, String>,
    reentrant_elapsed: Duration,
    total_elapsed: Duration,
}

/// Runs the exact deadlock shape: thread A parks inside `op`; thread B (the Dart
/// UI handler) waits for the `script.ui_request`, re-enters the pack *before*
/// answering, then answers. Returns the live harness (for post-round-trip probes)
/// alongside the observed outcomes.
fn run_parked_reentrant_roundtrip(tag: &str) -> (Harness, Roundtrip) {
    clear_ui_state();
    let harness = harness(
        tag,
        Duration::from_millis(UI_BUDGET_MS),
        Duration::from_millis(1_000),
    );
    harness
        .api
        .import(
            zip_with(ENTRY_SCRIPT, Some(DETAIL_SCRIPT), None),
            Some(KEY.to_string()),
        )
        .expect("import reentrancy pack");

    let started = Instant::now();
    let (outer, reentrant, reentrant_elapsed) = std::thread::scope(|scope| {
        // Thread A: the parked outer dispatch (holds `op` for the whole eval).
        let outer = scope.spawn(|| harness.api.run(KEY, "getAllApps", "{}"));
        // Thread B: the Dart UI handler. It re-enters *before* answering the park.
        let reentrant = scope.spawn(|| {
            let (request_id, _payload) =
                wait_for_ui_request("showVersionPicker", Duration::from_secs(2))
                    .expect("the parked call must emit a script.ui_request");
            let reentrant_started = Instant::now();
            let result =
                harness
                    .api
                    .run(KEY, "versionOptions", r#"{"appId":"com.example.app"}"#);
            let elapsed = reentrant_started.elapsed();
            crate::bridge::UiApi::new()
                .respond(request_id, r#"{"env":"sit"}"#.to_string())
                .expect("answering the park must succeed");
            (result, elapsed)
        });
        let outer = outer.join().expect("outer dispatch thread");
        let (reentrant, reentrant_elapsed) = reentrant.join().expect("ui-handler thread");
        (outer, reentrant, reentrant_elapsed)
    });
    let roundtrip = Roundtrip {
        outer,
        reentrant,
        reentrant_elapsed,
        total_elapsed: started.elapsed(),
    };
    (harness, roundtrip)
}

#[test]
fn ui_roundtrip_no_reentrancy_deadlock() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (harness, round) = run_parked_reentrant_roundtrip("reentrancy-deadlock");

    // The re-entrant call must fail FAST with the typed code, not block on `op`.
    let reentrant_error = round
        .reentrant
        .as_ref()
        .expect_err("the re-entrant dispatch must be rejected, not served");
    assert!(
        reentrant_error.contains(TYPED_CODE),
        "expected typed `{TYPED_CODE}`, got: {reentrant_error}"
    );
    assert!(
        round.reentrant_elapsed < Duration::from_millis(REENTRANT_FAST_MS),
        "re-entrant rejection took {}ms (must be < {REENTRANT_FAST_MS}ms); the guard did not short-circuit",
        round.reentrant_elapsed.as_millis()
    );

    // The parked outer call still succeeds once the UI answers — and its result
    // is the UI's answer, not a fabricated/null value.
    let outer = round.outer.expect("the parked outer call must complete");
    let outer_value: serde_json::Value =
        serde_json::from_str(&outer).expect("outer result is JSON");
    assert_eq!(
        outer_value["ui"]["ok"], true,
        "outer call must carry the answered UI value, got: {outer}"
    );

    // The whole round trip is well under the UI budget: no 30 s (or budget-long)
    // stall from the re-entrancy.
    assert!(
        round.total_elapsed < Duration::from_millis(UI_BUDGET_MS),
        "round trip took {}ms (must be < the {UI_BUDGET_MS}ms UI budget)",
        round.total_elapsed.as_millis()
    );
    println!(
        "[reentrancy] reentrant={}ms total={}ms outer={outer}",
        round.reentrant_elapsed.as_millis(),
        round.total_elapsed.as_millis()
    );

    // stale_state: the parked flag is cleared after the round trip, so a normal
    // dispatch that does not park is served rather than rejected as re-entrant.
    let after = harness
        .api
        .run(KEY, "searchApps", "{}")
        .expect("a post-roundtrip dispatch must not be seen as re-entrant");
    assert!(after.contains("searchApps"), "{after}");

    // A second park still works: the flag is reset per round trip, not latched.
    clear_ui_state();
    let responder = spawn_responder(
        "showVersionPicker",
        r#"{"env":"prod"}"#.to_string(),
        Duration::ZERO,
        None,
    );
    let second = harness
        .api
        .run(KEY, "getAllApps", "{}")
        .expect("a second park must still complete");
    responder.join().expect("responder").expect("respond");
    let second_value: serde_json::Value =
        serde_json::from_str(&second).expect("second result is JSON");
    assert_eq!(second_value["ui"]["ok"], true, "{second}");
}

#[test]
fn reentrant_jscall_rejected_typed() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (_harness, round) = run_parked_reentrant_roundtrip("reentrancy-typed");

    let error = round
        .reentrant
        .as_ref()
        .expect_err("the re-entrant jscall must be rejected with a typed error");
    assert!(
        error.contains(TYPED_CODE),
        "re-entrant error must literally contain `{TYPED_CODE}`, got: {error}"
    );
    // Not a panic, not a silent success, not a timeout — the typed re-entrancy code.
    assert!(
        !error.contains("CORE_E_SCRIPT_TIMEOUT"),
        "a parked re-entrancy must be rejected before any budget expiry: {error}"
    );
    assert!(
        round.outer.is_ok(),
        "the parked outer call must still complete: {:?}",
        round.outer
    );
    println!("[reentrancy] typed_rejection={error}");
}
