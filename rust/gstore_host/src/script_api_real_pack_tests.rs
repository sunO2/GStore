//! End-to-end proof that the REAL JS-channel pack's `getAppDetail` returns a rich
//! detail map through the RUST host (the on-device `ScriptApi::run` path), not
//! just the Dart engine.
//!
//! The pack sources are the exact files under `scripts/channels/src/pingan/`
//! (`entry.js`, `detail.js`, `meta.json`), embedded with `include_str!` so the
//! test is offline and fails loudly if the pack is edited out from under it. The
//! only stub is the transport: a queue-based
//! [`gstore_core::ports::fake::FakeHttpPort`] wrapped in the script adapter,
//! programmed with the two canned responses the pack's `getAppDetail` actually
//! consumes (`/sunflower/i/build-list`, then `/sunflower/i/build`). No real
//! network, no credentials (the pack's documented no-credential degraded path
//! still returns a detail map).
//!
//! The response payloads mirror `test/pingan_script_test.dart`'s
//! `_FakePinganApi::buildList(withFileUrl:false)` and `buildDetail(...)` so the
//! Rust host exercises the same contract the Dart suite already locks.

use std::sync::Arc;
use std::time::Duration;

use gstore_core::ports::fake::FakeHttpPort;
use gstore_core::ports::{HttpPort, HttpResponse};
use serde_json::Value;

use crate::http_port::{BufferedScriptHttp, ScriptHttp};
use crate::script_api_test_support::{clear_ui_state, harness_with_script_http, zip_with};
use crate::TEST_SERIAL;

const ENTRY_JS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/channels/src/pingan/entry.js"
));
const DETAIL_JS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/channels/src/pingan/detail.js"
));
const META_JSON: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/channels/src/pingan/meta.json"
));

/// `GET /sunflower/i/build-list` — mirrors the Dart suite's
/// `buildList(withFileUrl:false)`: an ios group and an android group whose build
/// carries `ipa[0].name` but no `fileurl`, so the pack resolves a proxy path
/// (credential-gated) rather than a direct URL.
const BUILD_LIST_JSON: &str = r#"{
  "appLogo": "/logo/app.png",
  "buildList": [
    { "_id": "bg-ios", "version": "2.0.0", "platform": "ios", "env": "sit",
      "publishedAt": 1700000000000, "status": "success", "__v": 1,
      "builds": [ { "identifier": "com.pingan.ios", "versionname": "平安口袋银行",
        "num": 2, "size": 8000, "installTimes": 1, "changelog": "ios changelog",
        "builtBy": "tester", "fileurl": [] } ] },
    { "_id": "bg-android", "version": "1.9.0", "platform": "android", "env": "sit",
      "publishedAt": 1690000000000, "status": "success", "__v": 6,
      "builds": [ { "identifier": "com.pingan.app", "versionname": "平安口袋银行",
        "num": 7, "size": 12345678, "installTimes": 99, "changelog": "修复若干问题",
        "builtBy": "ci-bot",
        "ipa": [ { "name": "com.pingan.app-1.9.0.apk", "_id": "ipa-1" } ],
        "fileurl": [] } ] }
  ]
}"#;

/// `GET /sunflower/i/build` — the build-detail completion response:
/// `build.builds` supplies the real `ipa[0].name`, and `appInfo.screenshots`
/// feeds the detail's top-level `screenshots` (which the UI renders from
/// `sections`).
const BUILD_JSON: &str = r#"{
  "build": {
    "_id": "bg-android",
    "version": "1.9.0",
    "builds": [ { "identifier": "com.pingan.app", "versionname": "平安口袋银行",
      "num": 7, "size": 12345678, "installTimes": 99, "changelog": "修复若干问题",
      "builtBy": "ci-bot",
      "ipa": [ { "name": "com.pingan.app-1.9.0.apk", "_id": "ipa-7" } ],
      "fileurl": [] } ]
  },
  "appInfo": { "displayname": "平安口袋银行", "intro": "平安口袋银行介绍",
    "name": "ibank", "screenshots": [ "/shots/1a.png", "/shots/1b.png" ] }
}"#;

fn json_response(json: &str) -> HttpResponse {
    HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: json.as_bytes().to_vec(),
    }
}

/// Builds the harness with a queue-based fake transport the caller keeps a handle
/// to, so responses can be programmed and calls inspected.
fn real_pack_harness(tag: &str, http: &FakeHttpPort) -> crate::script_api_test_support::Harness {
    let port: Arc<dyn HttpPort> = Arc::new(http.clone());
    let script_http: Arc<dyn ScriptHttp> = Arc::new(BufferedScriptHttp::new(port));
    harness_with_script_http(
        tag,
        script_http,
        // No UI responder: the pack's progressive `host.ui.call('updateDetail')`
        // pushes time out fast (each capped by this budget) and are swallowed by
        // the pack's try/catch, so they never affect the main chain.
        Duration::from_millis(50),
        Duration::from_secs(5),
    )
}

#[test]
fn real_pack_get_app_detail_returns_rich_detail_through_rust_host() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();

    // Given: the real pack imported under the Rust-lane key js_pingan, with the
    // two network responses its getAppDetail consumes, in call order (FIFO).
    let http = FakeHttpPort::new();
    http.push_response(json_response(BUILD_LIST_JSON)); // #1 /sunflower/i/build-list
    http.push_response(json_response(BUILD_JSON)); // #2 /sunflower/i/build
    let harness = real_pack_harness("real-pack-detail", &http);

    let info = harness
        .api
        .import(
            zip_with(ENTRY_JS, Some(DETAIL_JS), Some(META_JSON)),
            Some("js_pingan".to_string()),
        )
        .expect("import real pingan pack");
    assert_eq!(info.key, "js_pingan");
    assert_eq!(info.name, "平安测试商店");
    assert!(info.has_detail, "the real pack must ship detail.js");

    // When: the on-device path runs getAppDetail through the Rust host.
    let run = harness
        .api
        .run("js_pingan", "getAppDetail", r#"{"appId":"app-1"}"#)
        .expect("run getAppDetail");

    // Then: a NON-null, rich detail map (not the bare `null` the bug produced).
    let value: Value = serde_json::from_str(&run).expect("run JSON");
    let calls: Vec<String> = http.calls().into_iter().map(|call| call.url).collect();
    println!("[real-pack-detail] http_calls={calls:?}");
    println!("[real-pack-detail] run={run}");
    assert!(
        value.is_object(),
        "detail must be a non-null object, got: {run}"
    );

    assert_eq!(value["appId"], "app-1", "{run}");
    assert_eq!(value["name"], "平安口袋银行", "{run}");
    assert_eq!(value["version"], "1.9.0", "{run}");
    assert_eq!(value["packageName"], "com.pingan.app", "{run}");
    assert_eq!(value["extra"]["identifier"], "com.pingan.app", "{run}");

    // downloads: one entry, real ipa filename, size as a number, empty url (no creds).
    let downloads = value["downloads"].as_array().expect("downloads array");
    assert_eq!(downloads.len(), 1, "{run}");
    assert_eq!(downloads[0]["name"], "com.pingan.app-1.9.0.apk", "{run}");
    assert_eq!(downloads[0]["size"], 12345678, "{run}");
    assert_eq!(downloads[0]["version"], "1.9.0", "{run}");
    assert_eq!(downloads[0]["url"], "", "{run}");

    // sections + top-level screenshots (the UI renders the screenshot block from these).
    let sections = value["sections"].as_array().expect("sections array");
    assert!(sections.iter().any(|section| section == "downloads"), "{run}");
    assert!(
        sections.iter().any(|section| section == "screenshots"),
        "{run}"
    );
    assert_eq!(value["screenshots"].as_array().map(Vec::len), Some(2), "{run}");

    // The same build-list request also yields the version options, so the page
    // picker needs no extra round-trip.
    let version_options = &value["extra"]["versionOptions"];
    assert_eq!(version_options["currentEnv"], "sit", "{run}");
    assert_eq!(version_options["currentVersion"], "1.9.0", "{run}");
    assert_eq!(
        version_options["versions"].as_array().map(Vec::len),
        Some(1),
        "{run}"
    );
    assert_eq!(version_options["versions"][0]["buildCount"], 7, "{run}");

    // The pack made exactly the two expected requests, in order.
    assert_eq!(calls.len(), 2, "expected 2 HTTP calls, got {calls:?}");
    assert!(calls[0].contains("/sunflower/i/build-list"), "{calls:?}");
    assert!(calls[1].contains("/sunflower/i/build"), "{calls:?}");
}

/// Cheap contrast: `detailMenu` is implemented ONLY in detail.js (entry.js has no
/// such case -> `default: return null`), so a non-null menu proves the DETAIL
/// runtime served it. An entry-only method the pack's entry.js does not implement
/// (`getConfig`) returns `null` through the ENTRY runtime — the same
/// "no case -> null" shape `getAppDetail` hit pre-fix when it was mis-classified
/// as Entry (54c1ce0b moved it to Detail; this test does not revert that).
#[test]
fn real_pack_detail_only_method_routes_to_detail_runtime_not_entry() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();

    let http = FakeHttpPort::new();
    let harness = real_pack_harness("real-pack-contrast", &http);
    harness
        .api
        .import(
            zip_with(ENTRY_JS, Some(DETAIL_JS), Some(META_JSON)),
            Some("js_pingan".to_string()),
        )
        .expect("import real pingan pack");

    let menu = harness
        .api
        .run("js_pingan", "detailMenu", r#"{"appId":"app-1"}"#)
        .expect("run detailMenu");
    println!("[real-pack-contrast] detailMenu={menu}");
    let value: Value = serde_json::from_str(&menu).expect("menu JSON");
    assert!(
        value.is_array(),
        "detailMenu must return the detail runtime's menu: {menu}"
    );
    assert_eq!(value.as_array().map(Vec::len), Some(3), "{menu}");

    let cfg = harness
        .api
        .run("js_pingan", "getConfig", "{}")
        .expect("run getConfig");
    println!("[real-pack-contrast] getConfig(entry, unimplemented)={cfg}");
    assert_eq!(
        serde_json::from_str::<Value>(&cfg).expect("cfg JSON"),
        Value::Null,
        "{cfg}"
    );
}
