//! `ScriptApi` pack lifecycle: import/remove/refresh/env/run and policy.

use std::collections::HashMap;
use std::time::Duration;

use serde_json::Value;

use crate::script_api_test_support::{harness, zip_with};
use crate::TEST_SERIAL;

const ENV_SCRIPT: &str = r#"
function main(method, params) {
  if (method === 'getAllApps') {
    return { ok: true, data: {
      foo: host.env.get('FOO'),
      hasFoo: host.env.has('FOO'),
      all: host.env.all(),
      marker: 'v1'
    } };
  }
  return { ok: false, error: 'unexpected ' + method };
}
"#;

fn fast_harness(tag: &str) -> crate::script_api_test_support::Harness {
    harness(tag, Duration::from_millis(200), Duration::from_millis(100))
}

#[test]
fn script_api_import_remove_refresh_env_run() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("lifecycle");
    let meta = r#"{"name":"Life","description":"lifecycle pack","icon":"icons/a.png"}"#;
    let info = harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, Some(meta)),
            Some("js_life".to_string()),
        )
        .expect("import");
    assert_eq!(info.key, "js_life");
    assert_eq!(info.name, "Life");
    assert_eq!(info.description, "lifecycle pack");
    assert_eq!(info.icon, "icons/a.png");
    assert!(!info.has_detail);

    let list = harness.api.list().expect("list");
    println!("[import] {info:?}");
    println!("[list] {list:?}");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].key, "js_life");

    let first: Value =
        serde_json::from_str(&harness.api.run("js_life", "getAllApps", "{}").expect("run"))
            .expect("json");
    assert_eq!(first["marker"], "v1");
    assert!(first["foo"]["data"].is_null());
    assert_eq!(first["hasFoo"]["data"], false);

    let mut env = HashMap::new();
    env.insert("FOO".to_string(), "bar".to_string());
    env.insert("API_TOKEN".to_string(), "secret".to_string());
    println!("[run-before-env] {first}");
    harness
        .api
        .set_env("js_life", env.clone())
        .expect("set env");
    println!("[set_env] {env:?}");

    // Hot update: the same runtime sees the new snapshot, no refresh/restart.
    let second: Value =
        serde_json::from_str(&harness.api.run("js_life", "getAllApps", "{}").expect("run"))
            .expect("json");
    assert_eq!(second["foo"]["data"], "bar");
    assert_eq!(second["hasFoo"]["data"], true);
    assert_eq!(second["all"]["data"]["FOO"], "bar");
    println!("[run-after-env] {second}");
    assert_eq!(second["all"]["data"]["API_TOKEN"], "secret");

    // Refresh reloads the installed entry.js from disk.
    let dir = harness
        .root
        .join("files/channel_packs/js_life")
        .read_dir()
        .expect("pack root")
        .filter_map(Result::ok)
        .find(|entry| entry.path().is_dir())
        .expect("version dir")
        .path();
    std::fs::write(dir.join("entry.js"), ENV_SCRIPT.replace("'v1'", "'v2'"))
        .expect("rewrite entry.js");
    let refreshed = harness.api.refresh("js_life").expect("refresh");
    println!("[refresh] {refreshed:?}");
    assert_eq!(refreshed.key, "js_life");
    let third: Value =
        serde_json::from_str(&harness.api.run("js_life", "getAllApps", "{}").expect("run"))
            .expect("json");
    assert_eq!(third["marker"], "v2");
    println!("[run-after-refresh] {third}");
    assert_eq!(
        third["foo"]["data"], "bar",
        "refresh reseeds the persisted env"
    );
    assert_eq!(
        third["all"]["data"]["API_TOKEN"], "secret",
        "refresh keeps secrets, not just plaintext env"
    );

    harness.api.remove("js_life").expect("remove");
    println!("[remove] ok");
    assert!(harness.api.list().expect("list").is_empty());
    let missing = harness
        .api
        .run("js_life", "getAllApps", "{}")
        .expect_err("removed pack must fail");
    println!("[run-after-remove] {missing}");
    assert!(missing.starts_with("pack_not_found:"), "{missing}");
}

#[test]
fn script_api_import_without_expected_key_uses_stable_hash_key() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("hashkey");
    let zip = zip_with(ENV_SCRIPT, None, None);
    let first = harness.api.import(zip.clone(), None).expect("import 1");
    let second = harness.api.import(zip, None).expect("import 2");
    assert!(first.key.starts_with("js_pack_"), "{}", first.key);
    assert_eq!(first.key, second.key, "content hash keys must be stable");
}

#[test]
fn script_api_run_rejects_unsupported_methods_and_bad_params() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("rejects");
    harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, None),
            Some("js_rejects".to_string()),
        )
        .expect("import");

    let unsupported = harness
        .api
        .run("js_rejects", "deleteEverything", "{}")
        .expect_err("unsupported");
    assert!(unsupported.starts_with("unsupported:"), "{unsupported}");

    let bad_params = harness
        .api
        .run("js_rejects", "getAllApps", "[1,2]")
        .expect_err("bad params");
    assert!(bad_params.starts_with("invalid_argument:"), "{bad_params}");
}

#[test]
fn script_api_detail_method_requires_detail_js() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("nodetail");
    harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, Some(r#"{"name":"NoDetail"}"#)),
            Some("js_nodetail".to_string()),
        )
        .expect("import");
    assert!(!harness.api.list().expect("list")[0].has_detail);
    let error = harness
        .api
        .run("js_nodetail", "versionOptions", r#"{"appId":"a"}"#)
        .expect_err("detail required");
    assert!(error.starts_with("not_found:"), "{error}");
}

#[test]
fn script_api_scripts_never_see_the_channel_from_their_payload() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("isolation");
    // The script tries to read another channel's env and apps; both must stay
    // pinned to `js_iso` by the host, never by the script payload.
    let script = r#"
function main(method, params) {
  var apps = host.database.getAppsByChannel();
  var env = host.env.all();
  return { ok: true, data: { apps: apps.data, env: env.data } };
}
"#;
    harness
        .api
        .import(zip_with(script, None, None), Some("js_iso".to_string()))
        .expect("import");
    let run = harness.api.run("js_iso", "getAllApps", "{}").expect("run");
    let value: Value = serde_json::from_str(&run).expect("json");
    assert_eq!(value["apps"], serde_json::json!([]));
    assert_eq!(value["env"], serde_json::json!({}));
}
