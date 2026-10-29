//! `ScriptApi` pack lifecycle: import/remove/refresh/env/run and policy.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use gstore_core::dto::AppSummary;
use gstore_core::ports::{HttpOptions, HttpResponse};
use serde_json::Value;

use crate::http_port::{ScriptHttp, ScriptHttpLimits, TransportError};
use crate::script_api_test_support::{
    harness, harness_with_script_http, reopen, zip_with, zip_with_extra,
};
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
fn script_api_env_read_round_trips_including_sensitive() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("envread");
    harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, None),
            Some("js_envread".to_string()),
        )
        .expect("import");

    // A channel that never had env saved reads back an empty JSON object.
    assert_eq!(
        harness.api.env("js_envread").expect("env before set"),
        "{}",
        "a fresh channel has an empty env snapshot"
    );

    let mut env = HashMap::new();
    env.insert("PINGAN_USER".to_string(), "alice".to_string());
    env.insert("PINGAN_ENV".to_string(), "sit".to_string());
    // Sensitive name (is_sensitive_key): routed to the secret store, not the row.
    env.insert("API_TOKEN".to_string(), "s3cr3t".to_string());
    harness
        .api
        .set_env("js_envread", env.clone())
        .expect("set env");

    let raw = harness.api.env("js_envread").expect("env after set");
    let read: std::collections::BTreeMap<String, String> =
        serde_json::from_str(&raw).expect("env json");
    assert_eq!(
        read,
        env.clone().into_iter().collect(),
        "the read mirrors exactly what was written"
    );

    // A restart (fresh DbHandle over the same files) must still resolve the
    // sensitive value from the secret store, not just the plaintext row.
    let reopened = reopen(&harness);
    let raw = reopened.env("js_envread").expect("env after reopen");
    let read: std::collections::BTreeMap<String, String> =
        serde_json::from_str(&raw).expect("env json");
    assert_eq!(read.get("API_TOKEN").map(String::as_str), Some("s3cr3t"));
    assert_eq!(read.get("PINGAN_USER").map(String::as_str), Some("alice"));
    assert_eq!(read.get("PINGAN_ENV").map(String::as_str), Some("sit"));
    println!("[env-read-round-trip] {read:?}");
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
fn script_api_run_matches_dart_no_result_envelopes() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("envelopes");
    const SCRIPT: &str = r#"
function main(method) {
  switch (method) {
    case 'getAllApps': return { ok: false, error: 'script failed' };
    case 'searchApps': throw new Error('boom');
    case 'getAppInfo': return { ok: 'yes', data: { leaked: true } };
    case 'checkUpdate': return { ok: true, data: { kept: true } };
    default: return null;
  }
}
"#;
    harness
        .api
        .import(
            zip_with(SCRIPT, None, None),
            Some("js_envelope".to_string()),
        )
        .expect("import");

    let ok_false = harness
        .api
        .run("js_envelope", "getAllApps", "{}")
        .expect("ok:false is not a typed error");
    let threw = harness
        .api
        .run("js_envelope", "searchApps", "{}")
        .expect("throw is not a typed error");
    let malformed = harness
        .api
        .run("js_envelope", "getAppInfo", "{}")
        .expect("non-boolean ok is not a typed error");
    let null_result = harness
        .api
        .run("js_envelope", "doUpdate", "{}")
        .expect("null result");
    let ok_true = harness
        .api
        .run("js_envelope", "checkUpdate", "{}")
        .expect("ok:true still returns data");

    println!(
        "PASS | run envelope    | ok:false={ok_false} throw={threw} malformed={malformed} \
         null={null_result} ok:true={ok_true}"
    );
    assert_eq!(ok_false, "null", "{ok_false}");
    assert_eq!(threw, "null", "{threw}");
    assert_eq!(malformed, "null", "{malformed}");
    assert_eq!(null_result, "null", "{null_result}");
    assert_eq!(ok_true, r#"{"kept":true}"#, "{ok_true}");
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

const DETAIL_COUNTER_JS: &str = r#"
let __count = 0;
async function main(method, params) {
  __count = __count + 1;
  return { ok: true, data: { appId: params.appId, count: __count } };
}
"#;

fn detail_count(api: &crate::script_api::ScriptApiInner, key: &str, app_id: &str) -> u64 {
    let raw = api
        .run(key, "versionOptions", &format!(r#"{{"appId":"{app_id}"}}"#))
        .expect("detail run");
    let value: Value = serde_json::from_str(&raw).expect("detail json");
    value["count"].as_u64().expect("count")
}

#[test]
fn script_api_detail_runtimes_are_isolated_per_app() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("detail-isolation");
    harness
        .api
        .import(
            zip_with(
                "function main() { return null; }",
                Some(DETAIL_COUNTER_JS),
                None,
            ),
            Some("js_detail".to_string()),
        )
        .expect("import");

    assert_eq!(detail_count(&harness.api, "js_detail", "a"), 1);
    assert_eq!(detail_count(&harness.api, "js_detail", "a"), 2);
    assert_eq!(
        detail_count(&harness.api, "js_detail", "b"),
        1,
        "no bleed from a"
    );
    assert_eq!(detail_count(&harness.api, "js_detail", "b"), 2);
    assert_eq!(
        detail_count(&harness.api, "js_detail", "a"),
        3,
        "a keeps its state"
    );
    println!("PASS | detail isolation | a=1,2,3 b=1,2 | isolated per appId");
}

#[test]
fn script_api_detail_release_and_lru_cap() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("detail-release");
    harness
        .api
        .import(
            zip_with(
                "function main() { return null; }",
                Some(DETAIL_COUNTER_JS),
                None,
            ),
            Some("js_release".to_string()),
        )
        .expect("import");

    assert_eq!(detail_count(&harness.api, "js_release", "a"), 1);
    assert_eq!(detail_count(&harness.api, "js_release", "a"), 2);
    harness
        .api
        .release_detail("js_release", "a")
        .expect("release a");
    assert_eq!(
        detail_count(&harness.api, "js_release", "a"),
        1,
        "release resets state"
    );
    harness
        .api
        .release_detail("js_release", "a")
        .expect("release is idempotent");
    harness
        .api
        .release_detail("js_release", "never-created")
        .expect("unknown app is a no-op");
    harness
        .api
        .release_detail("js_absent", "a")
        .expect("unknown pack is a no-op");

    assert_eq!(detail_count(&harness.api, "js_release", "b"), 1);
    assert_eq!(
        detail_count(&harness.api, "js_release", "c"),
        1,
        "the 3rd distinct appId evicts the oldest (a)"
    );
    assert_eq!(
        detail_count(&harness.api, "js_release", "c"),
        2,
        "the newest runtime stayed live"
    );
    assert_eq!(
        detail_count(&harness.api, "js_release", "b"),
        2,
        "b stayed live"
    );
    assert_eq!(
        detail_count(&harness.api, "js_release", "a"),
        1,
        "a was evicted, so it got a fresh runtime"
    );
    println!("PASS | detail LRU       | cap=2 evicted the oldest, newest stayed; release resets state");
}

/// A minimal detail pack that implements the "更多" menu and the three custom
/// jscalls the Rust-lane detail channel forwards (`jsswitchVersion`,
/// `jsBuildHistory`, `jsswitchUA`). Before the `classify` extension those three
/// names were unclassified and `ScriptApi::run` rejected them as `unsupported`.
const DETAIL_DISPATCH_JS: &str = r#"
async function main(method, params) {
  switch (method) {
    case 'detailMenu': return { ok: true, data: [
      { action: '切换版本', jscall: 'jsswitchVersion' },
      { action: '历史构建', jscall: 'jsBuildHistory' },
      { action: '切换UA', jscall: 'jsswitchUA' },
    ] };
    case 'jsswitchVersion': return { ok: true, data: { switched: 'version', appId: params.appId } };
    case 'jsBuildHistory': return { ok: true, data: { history: true, appId: params.appId } };
    case 'jsswitchUA': return { ok: true, data: { ua: true, appId: params.appId } };
    default: return null;
  }
}
"#;

#[test]
fn script_api_run_routes_pack_detail_actions_to_the_detail_runtime() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("detail-actions");
    harness
        .api
        .import(
            zip_with(
                "function main() { return null; }",
                Some(DETAIL_DISPATCH_JS),
                None,
            ),
            Some("js_actions".to_string()),
        )
        .expect("import");

    // detailMenu routes to Detail and returns the pack's declared actions.
    let menu_raw = harness
        .api
        .run("js_actions", "detailMenu", r#"{"appId":"a"}"#)
        .expect("detailMenu");
    let menu: Value = serde_json::from_str(&menu_raw).expect("menu json");
    assert_eq!(menu.as_array().map(Vec::len), Some(3), "{menu}");
    assert_eq!(menu[0]["jscall"], "jsswitchVersion");

    // The pack's custom jscalls must route to Detail, never `unsupported`.
    for method in ["jsswitchVersion", "jsBuildHistory", "jsswitchUA"] {
        let raw = harness
            .api
            .run("js_actions", method, r#"{"appId":"a"}"#)
            .unwrap_or_else(|error| {
                panic!("`{method}` must route to Detail, got error: {error}")
            });
        let value: Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(value["appId"], "a", "{method} => {value}");
    }
    println!("PASS | detail actions | detailMenu + jsswitchVersion/jsBuildHistory/jsswitchUA routed to Detail");
}

#[test]
fn script_api_stored_apps_reads_the_shared_channel_apps_table() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("stored-apps");
    const STORE_JS: &str = r#"
function main(method) {
  if (method === 'doUpdate') {
    host.database.insertApps([{
      appId: 'app.saved', name: 'Saved', user: 'team', repositories: 'saved',
      icon: 'i', description: 'desc', category: 'a,b',
      extra: { packageName: 'pkg.saved' }
    }]);
    return { ok: true, data: true };
  }
  return null;
}
"#;
    harness
        .api
        .import(zip_with(STORE_JS, None, None), Some("js_store".to_string()))
        .expect("import");
    harness
        .api
        .run("js_store", "doUpdate", "{}")
        .expect("persist via host.database");

    let raw = harness.api.stored_apps("js_store").expect("stored apps");
    let value: Value = serde_json::from_str(&raw).expect("apps json");
    assert_eq!(value[0]["app_id"], "app.saved");
    assert_eq!(value[0]["package_name"], "pkg.saved");
    assert_eq!(value[0]["category"], serde_json::json!(["a", "b"]));
    println!("PASS | stored_apps      | channel_apps round-trip via ScriptChannelStore");
}

#[test]
fn script_api_stored_apps_survives_a_corrupt_pack() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("stored-apps-broken");
    const STORE_JS: &str = r#"
function main(method) {
  if (method === 'doUpdate') {
    host.database.insertApps([{
      appId: 'app.saved', name: 'Saved', user: 'team', repositories: 'saved',
      icon: 'i', description: 'desc', category: 'a,b',
      extra: { packageName: 'pkg.saved' }
    }]);
    return { ok: true, data: true };
  }
  return null;
}
"#;
    harness
        .api
        .import(zip_with(STORE_JS, None, None), Some("js_broken_store".to_string()))
        .expect("import");
    harness
        .api
        .run("js_broken_store", "doUpdate", "{}")
        .expect("persist via host.database");

    let dir = harness
        .root
        .join("files/channel_packs/js_broken_store")
        .read_dir()
        .expect("pack root")
        .filter_map(Result::ok)
        .find(|entry| entry.path().is_dir())
        .expect("version dir")
        .path();
    std::fs::write(dir.join("entry.js"), [0xff_u8, 0xfe, 0x00]).expect("corrupt entry.js");
    harness
        .api
        .refresh("js_broken_store")
        .expect("refresh drops the cached runtime");

    let raw = harness
        .api
        .stored_apps("js_broken_store")
        .expect("stored apps must not need a loadable pack");
    let value: Value = serde_json::from_str(&raw).expect("apps json");
    assert_eq!(value[0]["app_id"], "app.saved");
    assert_eq!(value[0]["package_name"], "pkg.saved");
    println!("PASS | stored_apps      | corrupt entry.js still lists saved rows");
}

#[test]
fn script_api_legacy_first_import_is_accepted_with_strict_first_preference() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("legacy-first");
    // An unknown root entry is a strict `pack_layout` failure but the exact
    // shape LegacyPermissive was built for. A first import must accept it.
    let zip = zip_with_extra(ENV_SCRIPT, &[("README.txt", b"legacy pack note")]);
    let info = harness
        .api
        .import(zip, Some("js_legacy_first".to_string()))
        .expect("legacy pack must import on first install");
    assert_eq!(info.key, "js_legacy_first");
    assert_eq!(
        harness.api.list().expect("list").len(),
        1,
        "legacy pack is listed"
    );
    let run = harness
        .api
        .run("js_legacy_first", "getAllApps", "{}")
        .expect("legacy pack runs");
    let value: Value = serde_json::from_str(&run).expect("run json");
    assert_eq!(value["marker"], "v1");
    println!("PASS | legacy import | strict reject -> legacy accept on first import");
}

#[test]
fn script_api_unsafe_pack_still_fails_under_both_policies() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("legacy-unsafe");
    // Path traversal is rejected by strict AND legacy; the retry must not
    // launder an unsafe archive into an install.
    let zip = zip_with_extra(ENV_SCRIPT, &[("../escape.js", b"escape")]);
    let error = harness
        .api
        .import(zip, Some("js_unsafe".to_string()))
        .expect_err("unsafe pack must fail");
    assert!(error.contains("pack_unsafe_entry"), "{error}");
    assert!(
        error.contains("legacy retry"),
        "the failure names both policies: {error}"
    );
    assert!(harness.api.list().expect("list").is_empty());
    println!("PASS | legacy import | unsafe path rejected by strict + legacy: {error}");
}

#[test]
fn script_api_remove_succeeds_when_entry_js_is_corrupt() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("remove-broken");
    harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, None),
            Some("js_broken".to_string()),
        )
        .expect("import");
    let dir = harness
        .root
        .join("files/channel_packs/js_broken")
        .read_dir()
        .expect("pack root")
        .filter_map(Result::ok)
        .find(|entry| entry.path().is_dir())
        .expect("version dir")
        .path();
    // Invalid UTF-8 is unreadable/unspawnable: the old remove (which loaded the
    // pack first) failed here. Removal must not need to load entry.js at all.
    std::fs::write(dir.join("entry.js"), [0xff_u8, 0xfe, 0x00]).expect("corrupt entry.js");
    harness
        .api
        .remove("js_broken")
        .expect("remove must succeed for a corrupt pack");
    assert!(harness.api.list().expect("list").is_empty());
    let missing = harness
        .api
        .run("js_broken", "getAllApps", "{}")
        .expect_err("removed pack must fail");
    assert!(missing.starts_with("pack_not_found:"), "{missing}");
    println!("PASS | remove        | corrupt entry.js removed, list empty");
}

struct TooLargeHttp;

impl ScriptHttp for TooLargeHttp {
    fn get_bounded(
        &self,
        _url: &str,
        _options: &HttpOptions,
        _limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        Err(TransportError::ResponseTooLarge {
            limit: gstore_script::DEFAULT_MAX_RESPONSE_BYTES,
            read: gstore_script::DEFAULT_MAX_RESPONSE_BYTES + 1,
        })
    }

    fn post_bounded(
        &self,
        _url: &str,
        _body: &[u8],
        _options: &HttpOptions,
        _limits: ScriptHttpLimits,
    ) -> Result<HttpResponse, TransportError> {
        Err(TransportError::ResponseTooLarge {
            limit: gstore_script::DEFAULT_MAX_RESPONSE_BYTES,
            read: gstore_script::DEFAULT_MAX_RESPONSE_BYTES + 1,
        })
    }
}

#[test]
fn script_api_streamed_limit_surfaces_typed_envelope_without_data() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = harness_with_script_http(
        "stream-limit",
        Arc::new(TooLargeHttp),
        Duration::from_millis(200),
        Duration::from_millis(100),
    );
    const SCRIPT: &str = r#"
function main() {
  var res = host.network.get('http://127.0.0.1/too-big', {});
  return { ok: true, data: {
    ok: res.ok,
    hasData: Object.prototype.hasOwnProperty.call(res, 'data'),
    error: res.error
  } };
}
"#;
    harness
        .api
        .import(zip_with(SCRIPT, None, None), Some("js_stream".to_string()))
        .expect("import");
    let raw = harness
        .api
        .run("js_stream", "getAllApps", "{}")
        .expect("run");
    let value: Value = serde_json::from_str(&raw).expect("json");
    assert_eq!(value["ok"], false, "{value}");
    assert_eq!(value["hasData"], false, "no partial data: {value}");
    let error = value["error"].as_str().expect("error string");
    assert!(error.contains("CORE_E_SCRIPT_LIMIT"), "{error}");
    assert!(error.contains("aborted after"), "{error}");
    println!("PASS | streamed limit | envelope={value}");
}

#[test]
fn script_api_lists_a_pack_with_malformed_meta() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("list-bad-meta");
    // A pack whose optional meta.json is not valid JSON (e.g. a BOM or a
    // trailing comma) is accepted by the legacy-permissive import and must stay
    // listed and runnable: the read path mirrors Dart `ChannelPackage._parseMeta`
    // and ignores the malformed metadata instead of failing.
    let info = harness
        .api
        .import(
            zip_with(ENV_SCRIPT, None, Some("{\"name\": \"truncated\"")),
            Some("js_badmeta".to_string()),
        )
        .expect("legacy-permissive import accepts a malformed meta.json");
    assert_eq!(info.key, "js_badmeta");
    assert_eq!(info.name, "js_badmeta", "name falls back to the key");

    let list = harness.api.list().expect("list must not fail on a bad meta.json");
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(list[0].key, "js_badmeta");

    let run = harness
        .api
        .run("js_badmeta", "getAllApps", "{}")
        .expect("a malformed meta.json must not block running the pack");
    let value: Value = serde_json::from_str(&run).expect("run json");
    assert_eq!(value["marker"], "v1");
    println!("PASS | list          | malformed meta.json ignored, pack still listed and runnable");
}

#[test]
fn script_api_list_skips_a_pack_whose_version_dir_is_missing() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("list-missing-dir");
    harness
        .api
        .import(zip_with(ENV_SCRIPT, None, None), Some("js_keep".to_string()))
        .expect("import keep");
    harness
        .api
        .import(zip_with(ENV_SCRIPT, None, None), Some("js_gone".to_string()))
        .expect("import gone");

    let gone_root = harness.root.join("files/channel_packs/js_gone");
    std::fs::remove_dir_all(&gone_root).expect("drop the version directory");

    // One pack whose files vanished must not blank the whole list: the healthy
    // pack is still listed and the broken row is skipped.
    let list = harness.api.list().expect("list must survive one broken pack");
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(list[0].key, "js_keep");
    println!("PASS | list          | a broken pack is skipped, the healthy pack is listed");
}

/// The demoted `ScriptApi` surface: pack lifecycle + `env` + `config` only.
///
/// The JS **data** engine (`ScriptApi::run`) is `#[frb(ignore)]`d, so the
/// generated Dart binding has no `run` and the Dart data path reads JS channel
/// data through `ChannelApi` / `RustChannelFacade`. This test proves the
/// retained surface still round-trips and that `run` is off the FRB
/// (Dart-facing) wire while remaining a crate-internal `ScriptApiInner` method.
#[test]
fn script_api_lifecycle_only() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("lifecycle-only");

    let entry = "function main(method){ return method === 'getAllApps' ? \
                 { ok: true, data: [] } : null; }";
    let info = harness
        .api
        .import(
            zip_with(entry, None, Some(r#"{"name":"LifeOnly"}"#)),
            Some("js_life_only".to_string()),
        )
        .expect("import");
    assert_eq!(info.key, "js_life_only");

    let list = harness.api.list().expect("list");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].key, "js_life_only");

    // storedApps / addApp: the retained script-domain store.
    assert_eq!(
        harness.api.stored_apps("js_life_only").expect("stored"),
        "[]"
    );
    harness
        .api
        .add_app(
            "js_life_only",
            AppSummary {
                app_id: "com.example.life".to_string(),
                package_name: Some("com.example.life.pkg".to_string()),
                name: "LifeOnly".to_string(),
                user: "team".to_string(),
                repositories: "repo".to_string(),
                icon: "icon".to_string(),
                des: "desc".to_string(),
                readme: None,
                category: Some(vec!["Tools".to_string()]),
                extra: None,
                labels: Vec::new(),
            },
        )
        .expect("add_app");
    let stored = harness.api.stored_apps("js_life_only").expect("stored");
    assert!(stored.contains("com.example.life"), "{stored}");

    // env: the retained channel-scoped snapshot.
    let mut env = HashMap::new();
    env.insert("FOO".to_string(), "bar".to_string());
    harness.api.set_env("js_life_only", env).expect("set_env");
    let env_json: Value =
        serde_json::from_str(&harness.api.env("js_life_only").expect("env")).expect("env json");
    assert_eq!(env_json["FOO"], "bar");

    // config: the retained hot-update snapshot.
    let mut config = HashMap::new();
    config.insert("k".to_string(), "\"v\"".to_string());
    harness
        .api
        .set_config("js_life_only", config)
        .expect("set_config");

    // refresh + remove: lifecycle.
    assert_eq!(
        harness.api.refresh("js_life_only").expect("refresh").key,
        "js_life_only"
    );
    harness.api.remove("js_life_only").expect("remove");
    assert!(harness.api.list().expect("list").is_empty());

    // `run` is off the FRB (Dart-facing) surface: the generated wire has no
    // `ScriptApi_run` binding. It survives only as a crate-internal engine.
    assert!(
        !include_str!("frb_generated.rs").contains("ScriptApi_run"),
        "ScriptApi::run must be off the FRB (Dart-facing) surface"
    );
    let _internal_engine = crate::script_api::ScriptApiInner::run;
}
