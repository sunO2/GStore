//! `ScriptApi` park exemption: a UI round-trip that outlives the remaining
//! cumulative budget still completes, and the rest of the budget stays charged.

use std::time::{Duration, Instant};

use serde_json::Value;

use crate::script_api_test_support::{
    clear_ui_state, harness_with_cumulative, spawn_responder, zip_with,
};
use crate::TEST_SERIAL;

const CUMULATIVE_MS: u64 = 400;
const BURN_MS: u64 = 150;
const PARK_MS: u64 = 280;
const POST_UNPARK_JS_MS: u64 = 20;
const OVERSHOOT_MS: u64 = 320;

const PARK_SCRIPT: &str = r#"
function main(method, params) {
  var p = params || {};
  if (p.burn) {
    var t = Date.now();
    while (Date.now() - t < p.burn) {}
  }
  if (!p.ui) return { ok: true, data: { burn: p.burn || 0 } };
  var res = host.ui.call('showVersionPicker', {});
  if (p.after) {
    var t2 = Date.now();
    while (Date.now() - t2 < p.after) {}
  }
  return { ok: true, data: { ui: res } };
}
"#;

#[test]
fn script_api_park_exempts_cumulative_budget_without_resetting_it() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();
    let harness = harness_with_cumulative(
        "park-cumulative",
        Duration::from_millis(500),
        Duration::from_millis(1_000),
        Duration::from_millis(CUMULATIVE_MS),
    );
    harness
        .api
        .import(
            zip_with(PARK_SCRIPT, None, None),
            Some("js_parked_budget".to_string()),
        )
        .expect("import");

    let started = Instant::now();
    let first = harness
        .api
        .run(
            "js_parked_budget",
            "getAllApps",
            &format!(r#"{{"burn":{BURN_MS}}}"#),
        )
        .expect("first burn fits");
    let first_spent = started.elapsed();
    let remaining = Duration::from_millis(CUMULATIVE_MS).saturating_sub(first_spent);
    println!(
        "[park] budget={CUMULATIVE_MS}ms first_burn={BURN_MS}ms spent={}ms remaining={}ms first={first}",
        first_spent.as_millis(),
        remaining.as_millis()
    );
    assert!(
        remaining < Duration::from_millis(PARK_MS),
        "test premise: the parked wait must exceed the remaining budget"
    );

    let responder = spawn_responder(
        "showVersionPicker",
        r#"{"env":"sit"}"#.to_string(),
        Duration::from_millis(PARK_MS),
        None,
    );
    let parked = harness
        .api
        .run(
            "js_parked_budget",
            "getAllApps",
            &format!(r#"{{"ui":true,"after":{POST_UNPARK_JS_MS}}}"#),
        )
        .expect("parked round-trip larger than the remaining budget");
    responder.join().expect("responder").expect("respond");
    let parked_value: Value = serde_json::from_str(&parked).expect("parked JSON");
    println!("[park] parked_run={parked}");
    assert_eq!(parked_value["ui"]["ok"], true, "{parked}");

    // If parking had reset the clock, the full 400 ms would remain and the
    // 320 ms overshoot would pass. A typed limit proves ~230 ms remained.
    let overshoot = harness.api.run(
        "js_parked_budget",
        "getAllApps",
        &format!(r#"{{"burn":{OVERSHOOT_MS}}}"#),
    );
    println!("[park] overshoot={OVERSHOOT_MS}ms outcome={overshoot:?}");
    let error = overshoot.expect_err("the remaining budget must be charged after unpark");
    assert!(error.contains("CORE_E_SCRIPT_LIMIT"), "{error}");
}
