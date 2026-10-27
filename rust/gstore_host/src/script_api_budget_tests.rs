//! `ScriptApi.run` uses the normal eval budget, never the long-eval budget.
//!
//! Three proofs, each with a small overridden budget so the suite stays fast:
//! an unparked infinite loop, bounded pure-JS work, and a parked UI wait that is
//! longer than the normal budget but still succeeds.

use std::time::{Duration, Instant};

use crate::script_api_test_support::harness;
use crate::script_api_test_support::zip_with;
use crate::TEST_SERIAL;

const LOOP_SCRIPT: &str = r#"
function main(method, params) {
  while (true) {}
}
"#;

const BURN_SCRIPT: &str = r#"
function main(method, params) {
  var until = Date.now() + 500;
  while (Date.now() < until) {}
  return { ok: true, data: 'finished' };
}
"#;

#[test]
fn script_api_run_infinite_loop_stops_at_normal_budget_not_long() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let normal = Duration::from_millis(60);
    // A long budget would be UI budget + 5 s (here 10 s), far beyond the cap
    // this test is willing to wait for.
    let ui_budget = Duration::from_secs(5);
    let harness = harness("budget-loop", ui_budget, normal);
    harness
        .api
        .import(
            zip_with(LOOP_SCRIPT, None, None),
            Some("js_budget_loop".to_string()),
        )
        .expect("import");

    let started = Instant::now();
    let error = harness
        .api
        .run("js_budget_loop", "getAllApps", "{}")
        .expect_err("an unparked infinite loop must time out");
    let elapsed = started.elapsed();
    println!(
        "[budget-loop] normal={}ms long_floor={}ms elapsed={}ms error={error}",
        normal.as_millis(),
        (ui_budget + Duration::from_secs(5)).as_millis(),
        elapsed.as_millis()
    );
    assert!(error.contains("CORE_E_SCRIPT_TIMEOUT"), "{error}");
    assert!(
        elapsed < Duration::from_secs(2),
        "infinite loop ran {elapsed:?}; the long budget leaked into ScriptApi.run"
    );
}

#[test]
fn script_api_run_pure_js_over_normal_budget_is_not_parked() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let normal = Duration::from_millis(60);
    let harness = harness("budget-burn", Duration::from_secs(5), normal);
    harness
        .api
        .import(
            zip_with(BURN_SCRIPT, None, None),
            Some("js_budget_burn".to_string()),
        )
        .expect("import");

    let started = Instant::now();
    let error = harness
        .api
        .run("js_budget_burn", "getAllApps", "{}")
        .expect_err("unparked JS work beyond the normal budget must fail");
    let elapsed = started.elapsed();
    println!(
        "[budget-burn] normal={}ms js=500ms elapsed={}ms error={error}",
        normal.as_millis(),
        elapsed.as_millis()
    );
    assert!(error.contains("CORE_E_SCRIPT_TIMEOUT"), "{error}");
    assert!(
        elapsed < Duration::from_secs(1),
        "bounded JS ran {elapsed:?}; it should stop at the normal budget"
    );
}
