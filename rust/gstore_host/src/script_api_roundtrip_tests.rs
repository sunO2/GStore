//! `ScriptApi` <-> `UiApi` round-trip tests (Todo 5 QA happy path).

use std::time::{Duration, Instant};

use serde_json::Value;

use crate::script_api_test_support::{
    clear_ui_state, harness, spawn_responder, wait_for_ui_request, zip_with,
};
use crate::{ui_api, TEST_SERIAL};

const PICKER_SCRIPT: &str = r#"
function main(method, params) {
  if (method === 'getAllApps') {
    var res = host.ui.call('showVersionPicker', {
      title: '选择版本', envs: ['sit'], versions: [], currentEnv: 'sit'
    });
    return { ok: true, data: { ui: res } };
  }
  return { ok: false, error: 'unexpected method ' + method };
}
"#;

const ALL_HANDLERS_SCRIPT: &str = r#"
var UI = {
  getAllApps: 'showVersionPicker',
  searchApps: 'showBuildHistory',
  getAppInfo: 'refreshDetail',
  getAppDetail: 'updateDownloadList',
  checkAppUpdate: 'showUAPicker',
  checkUpdate: 'updateDetail',
  doUpdate: 'setBusy',
  versionOptions: 'download'
};
function main(method, params) {
  var ui = UI[method];
  if (!ui) return { ok: false, error: 'no ui handler for ' + method };
  var res = host.ui.call(ui, params || {});
  return { ok: true, data: { ui: ui, res: res } };
}
"#;

#[test]
fn script_api_ui_roundtrip_end_to_end() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();
    let harness = harness(
        "roundtrip",
        Duration::from_millis(500),
        Duration::from_millis(100),
    );
    let zip = zip_with(PICKER_SCRIPT, None, Some(r#"{"name":"Picker"}"#));
    let info = harness
        .api
        .import(zip, Some("js_roundtrip".to_string()))
        .expect("import");
    assert_eq!(info.key, "js_roundtrip");
    assert_eq!(info.name, "Picker");

    let responder = spawn_responder(
        "showVersionPicker",
        r#"{"env":"sit","version":"1.0"}"#.to_string(),
        Duration::ZERO,
        Some("选择版本".to_string()),
    );
    let run = harness
        .api
        .run("js_roundtrip", "getAllApps", r#"{"forceRefresh":true}"#)
        .expect("run getAllApps");
    let (request_id, payload) = responder.join().expect("responder").expect("respond");
    assert!(request_id.starts_with("ui-"), "{request_id}");
    assert_eq!(payload["kind"], "showVersionPicker");
    assert_eq!(payload["title"], "选择版本");
    assert_eq!(payload["fields"], serde_json::json!([]));

    let value: Value = serde_json::from_str(&run).expect("run JSON");
    println!(
        "[roundtrip] import={info:?} request_id={request_id} event_kind={} event_message={} run={run}",
        payload["kind"], payload["message"]
    );
    assert_eq!(value["ui"]["ok"], true);
    assert_eq!(value["ui"]["data"]["env"], "sit");
    assert_eq!(value["ui"]["data"]["version"], "1.0");
}

#[test]
fn script_api_ui_roundtrip_all_eight_handlers() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness(
        "handlers",
        Duration::from_millis(500),
        Duration::from_millis(100),
    );
    let zip = zip_with(
        ALL_HANDLERS_SCRIPT,
        Some(ALL_HANDLERS_SCRIPT),
        Some(r#"{"name":"Handlers"}"#),
    );
    harness
        .api
        .import(zip, Some("js_handlers".to_string()))
        .expect("import");

    let cases: [(&str, &str, &str, &str); 8] = [
        (
            "getAllApps",
            "showVersionPicker",
            r#"{"title":"选择版本","envs":["sit"],"versions":[]}"#,
            "选择版本",
        ),
        (
            "searchApps",
            "showBuildHistory",
            r#"{"version":"1.0.0","env":"uat","builds":[{"num":3,"ipaName":"a.apk"}]}"#,
            "1.0.0",
        ),
        (
            "getAppInfo",
            "refreshDetail",
            r#"{"appId":"a","env":"sit","version":"1.0"}"#,
            "\"appId\":\"a\"",
        ),
        (
            "getAppDetail",
            "updateDownloadList",
            r#"{"downloads":[{"url":"u","name":"n","size":1024}]}"#,
            "\"url\":\"u\"",
        ),
        (
            "checkAppUpdate",
            "showUAPicker",
            r#"{"options":[{"ua":"agent/1.0"}],"current":"agent/1.0"}"#,
            "agent/1.0",
        ),
        (
            "checkUpdate",
            "updateDetail",
            r#"{"name":"x","sections":["downloads"],"downloads":[]}"#,
            "\"name\":\"x\"",
        ),
        (
            "doUpdate",
            "setBusy",
            r#"{"visible":true,"label":"更新中"}"#,
            "更新中",
        ),
        (
            "versionOptions",
            "download",
            r#"{"url":"https://example.test/a.apk","name":"a.apk","size":7,"version":"1.0"}"#,
            "a.apk",
        ),
    ];

    for (method, ui_method, params, fragment) in cases {
        clear_ui_state();
        let responder = spawn_responder(
            ui_method,
            format!(r#"{{"handler":"{ui_method}"}}"#),
            Duration::ZERO,
            Some(fragment.to_string()),
        );
        let run = harness
            .api
            .run("js_handlers", method, params)
            .unwrap_or_else(|error| panic!("{method} failed: {error}"));
        let (request_id, payload) = responder.join().expect("responder").expect("respond");
        assert!(request_id.starts_with("ui-"));
        assert_eq!(payload["kind"], ui_method);
        let value: Value = serde_json::from_str(&run).expect("run JSON");
        println!(
            "[handler] method={method} ui={ui_method} request_id={request_id} event_kind={} run={run}",
            payload["kind"]
        );
        assert_eq!(value["ui"], ui_method, "{method}");
        assert_eq!(value["res"]["ok"], true, "{method}: {run}");
        assert_eq!(value["res"]["data"]["handler"], ui_method, "{method}");
    }
}

#[test]
fn script_api_ui_roundtrip_parked_wait_beats_normal_eval_budget() {
    // The normal eval budget (40 ms) is deliberately shorter than the parked
    // wait (120 ms). A successful result proves the park suspension extends the
    // normal deadline; the dispatch does not fall back to the long budget.
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();
    let harness = harness(
        "parked",
        Duration::from_millis(250),
        Duration::from_millis(40),
    );
    let zip = zip_with(PICKER_SCRIPT, None, None);
    harness
        .api
        .import(zip, Some("js_parked".to_string()))
        .expect("import");
    let responder = spawn_responder(
        "showVersionPicker",
        r#"{"env":"sit"}"#.to_string(),
        Duration::from_millis(120),
        None,
    );
    let started = Instant::now();
    let run = harness
        .api
        .run("js_parked", "getAllApps", "{}")
        .expect("parked run");
    let elapsed = started.elapsed();
    responder.join().expect("responder").expect("respond");
    let value: Value = serde_json::from_str(&run).expect("run JSON");
    println!(
        "[budget-park] normal=40ms park=120ms elapsed={}ms run={run}",
        elapsed.as_millis()
    );
    assert_eq!(value["ui"]["ok"], true, "{run}");
}

#[test]
fn script_api_ui_roundtrip_unknown_request_is_typed() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let error = crate::bridge::UiApi::new()
        .respond("missing-request".to_string(), "null".to_string())
        .expect_err("unknown id");
    println!("[unknown-request] respond_error={error}");
    assert!(error.starts_with(ui_api::UI_UNKNOWN_REQUEST), "{error}");
}

#[test]
fn script_api_ui_roundtrip_timeout_envelope_and_expired_id() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();
    let harness = harness(
        "timeout",
        Duration::from_millis(60),
        Duration::from_millis(40),
    );
    let zip = zip_with(PICKER_SCRIPT, None, None);
    harness
        .api
        .import(zip, Some("js_timeout".to_string()))
        .expect("import");

    let run = harness
        .api
        .run("js_timeout", "getAllApps", "{}")
        .expect("run returns the timeout envelope");
    let value: Value = serde_json::from_str(&run).expect("run JSON");
    let envelope = &value["ui"];
    assert_eq!(envelope["ok"], false, "{run}");
    let error = envelope["error"].as_str().unwrap_or_default();
    println!("[timeout] run={run}");
    assert!(error.contains("CORE_E_SCRIPT_TIMEOUT"), "{error}");

    // The request id is still in the event ring; answering it now is a typed
    // "expired" failure, not a panic and not a silent success.
    let (request_id, _) =
        wait_for_ui_request("showVersionPicker", Duration::from_secs(1)).expect("event");
    let late = crate::bridge::UiApi::new()
        .respond(request_id.clone(), "null".to_string())
        .expect_err("expired id");
    println!("[timeout] expired request_id={request_id} respond_error={late}");
    assert!(late.starts_with(ui_api::UI_UNKNOWN_REQUEST), "{late}");
}

const ENTRY_NO_DETAIL: &str = r#"
function main(method, params) { return { ok: false, error: 'entry: ' + method }; }
"#;
const DETAIL_ONLY: &str = r#"
function main(method, params) {
  if (method === 'getAppDetail') {
    return { ok: true, data: { appId: params.appId, name: 'detail-only', downloads: [] } };
  }
  return { ok: false, error: 'unexpected ' + method };
}
"#;

#[test]
fn get_app_detail_routes_to_detail_runtime() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness(
        "detailroute",
        Duration::from_millis(500),
        Duration::from_millis(100),
    );
    let zip = zip_with(
        ENTRY_NO_DETAIL,
        Some(DETAIL_ONLY),
        Some(r#"{"name":"DetailOnly"}"#),
    );
    harness
        .api
        .import(zip, Some("js_detailonly".to_string()))
        .expect("import");
    let run = harness
        .api
        .run("js_detailonly", "getAppDetail", r#"{"appId":"a"}"#)
        .expect("run");
    let value: Value = serde_json::from_str(&run).expect("run JSON");
    println!("[detail-route] run={run}");
    assert_eq!(value["name"], "detail-only", "{run}"); // fails pre-fix: "null"
    assert_eq!(value["appId"], "a", "{run}");
}
