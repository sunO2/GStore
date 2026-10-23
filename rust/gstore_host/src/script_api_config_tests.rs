//! `ScriptApi` config injection: channel-scoped `host.config.get` parity.

use std::collections::HashMap;
use std::time::Duration;

use serde_json::Value;

use crate::script_api_test_support::{harness, zip_with};
use crate::TEST_SERIAL;

const CONFIG_SCRIPT: &str = r#"
function main(method, params) {
  if (method === 'getAllApps') {
    return { ok: true, data: {
      hit: host.config.get('channel.region'),
      retries: host.config.get('channel.retries'),
      miss: host.config.get('channel.missing')
    } };
  }
  return { ok: false, error: 'unexpected ' + method };
}
"#;

fn run_config(harness: &crate::script_api_test_support::Harness, key: &str) -> Value {
    let run = harness
        .api
        .run(key, "getAllApps", "{}")
        .expect("run config");
    serde_json::from_str(&run).expect("run JSON")
}

#[test]
fn script_api_config_hit_and_miss() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness(
        "config-hit",
        Duration::from_millis(200),
        Duration::from_millis(200),
    );
    harness
        .api
        .import(
            zip_with(CONFIG_SCRIPT, None, None),
            Some("js_config".to_string()),
        )
        .expect("import");

    let before = run_config(&harness, "js_config");
    println!("[config-before] {before}");
    assert!(before["hit"]["data"].is_null(), "{before}");
    assert!(before["miss"]["data"].is_null(), "{before}");

    let mut config = HashMap::new();
    config.insert("channel.region".to_string(), "\"sit\"".to_string());
    config.insert("channel.retries".to_string(), "3".to_string());
    harness
        .api
        .set_config("js_config", config.clone())
        .expect("set config");
    println!("[config-set] {config:?}");

    let after = run_config(&harness, "js_config");
    println!("[config-after] {after}");
    assert_eq!(after["hit"]["ok"], true, "{after}");
    assert_eq!(after["hit"]["data"], "sit", "{after}");
    assert_eq!(after["retries"]["data"], 3, "{after}");
    assert!(after["miss"]["data"].is_null(), "{after}");
}

#[test]
fn script_api_config_is_channel_scoped() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness(
        "config-scope",
        Duration::from_millis(200),
        Duration::from_millis(200),
    );
    for key in ["js_config_a", "js_config_b"] {
        harness
            .api
            .import(zip_with(CONFIG_SCRIPT, None, None), Some(key.to_string()))
            .expect("import");
    }

    let mut config = HashMap::new();
    config.insert("channel.region".to_string(), "\"A\"".to_string());
    harness
        .api
        .set_config("js_config_a", config)
        .expect("set config A");

    let a = run_config(&harness, "js_config_a");
    let b = run_config(&harness, "js_config_b");
    println!("[config-scope] a={a} b={b}");
    assert_eq!(a["hit"]["data"], "A", "{a}");
    assert!(b["hit"]["data"].is_null(), "b must not see a's config: {b}");
}

#[test]
fn script_api_config_rejects_invalid_json_without_mutating_the_map() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness(
        "config-invalid",
        Duration::from_millis(200),
        Duration::from_millis(200),
    );
    harness
        .api
        .import(
            zip_with(CONFIG_SCRIPT, None, None),
            Some("js_config_bad".to_string()),
        )
        .expect("import");

    let error = harness
        .api
        .set_config(
            "js_config_bad",
            HashMap::from([("channel.region".to_string(), "not-json".to_string())]),
        )
        .expect_err("invalid JSON must be rejected");
    println!("[config-invalid] error={error}");
    assert!(error.starts_with("invalid_argument:"), "{error}");

    let after = run_config(&harness, "js_config_bad");
    assert!(after["hit"]["data"].is_null(), "{after}");
}
