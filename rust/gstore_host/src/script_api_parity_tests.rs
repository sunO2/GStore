//! Real-engine parity for the Rust script lane (Plan-Todo 7 / Closeout-B3).
//!
//! # What these assertions prove
//!
//! `script_api_real_lane_parity_getconfig_sendmessage_uicall` imports a real
//! pack (a dedicated fixture, see `tests/fixtures/parity_entry.js`) and runs it
//! through the **real** rquickjs runtime, the **real** `ScriptHostImpl`, the
//! real SQLite config snapshot, and the real UI park/respond bridge. Every
//! expected value is composed by the script from its input or from a host
//! round-trip, so no harness constant can satisfy the assertion.
//!
//! `script_api_real_asset_example_js_parses_and_runs` reads the shipped
//! `assets/channels/example.js` from disk and executes its real `getAllApps`
//! entry point, so "example.js runs" is proven rather than implied.
//!
//! # Honest split
//!
//! REAL: QuickJS eval, `host.config.get`, `host.ui.call` emit/park/respond,
//! pack import, SQLite `channel_packs`/`channel_env` reads, and the actual asset
//! bytes. SEAM: the fake HTTP port (`FakeHttpPort`, empty 200 body) and the
//! per-test temp root — harness plumbing, never an asserted value.
//!
//! The fixture path can be overridden with `GSTORE_SCRIPT_PARITY_FIXTURE` so the
//! red-first check can point at a mutated copy without committing a mutation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

use crate::script_api_test_support::{clear_ui_state, harness, spawn_responder, zip_with};
use crate::TEST_SERIAL;

const FIXTURE_ENV: &str = "GSTORE_SCRIPT_PARITY_FIXTURE";

fn read_file(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()))
}

fn parity_fixture_source() -> String {
    if let Some(path) = std::env::var_os(FIXTURE_ENV) {
        return read_file(&PathBuf::from(path));
    }
    read_file(&Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/parity_entry.js"))
}

fn example_asset_source() -> String {
    read_file(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/channels/example.js"))
}

fn parse(raw: &str, method: &str) -> Value {
    serde_json::from_str(raw)
        .unwrap_or_else(|error| panic!("{method} result is not JSON: {error}; raw={raw}"))
}

#[test]
fn script_api_real_lane_parity_getconfig_sendmessage_uicall() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();
    let harness = harness(
        "real-lane-parity",
        Duration::from_millis(500),
        Duration::from_millis(500),
    );
    harness
        .api
        .import(
            zip_with(&parity_fixture_source(), None, None),
            Some("js_real_parity".to_string()),
        )
        .expect("import real parity fixture");
    println!("[real-lane:root] {}", harness.root.display());
    harness
        .api
        .set_config(
            "js_real_parity",
            HashMap::from([("channel.region".to_string(), "\"sit\"".to_string())]),
        )
        .expect("inject channel config snapshot");

    // getConfig: version and proxy are concatenated inside JS from the params;
    // `echo` can only come from `'cfg:' + params.token` in the script.
    let config = parse(
        &harness
            .api
            .run(
                "js_real_parity",
                "getConfig",
                r#"{"major":"2026","minor":"1","host":"127.0.0.1","token":"T-42"}"#,
            )
            .expect("run getConfig through the real engine"),
        "getConfig",
    );
    println!("[real-lane:getConfig] {config}");
    assert_eq!(
        config,
        json!({
            "version": "2026.1",
            "proxy": "http://127.0.0.1:7890",
            "echo": "cfg:T-42",
        })
    );

    // `sendMessage` is a JS bridge helper, not a ScriptApi dispatch name, so
    // `getAllApps` carries it: the script reads the injected `channel.region`
    // through the real host and appends its own token.
    let message = parse(
        &harness
            .api
            .run("js_real_parity", "getAllApps", r#"{"token":"L-7"}"#)
            .expect("run the sendMessage contract through the real engine"),
        "sendMessage",
    );
    println!("[real-lane:sendMessage] {message}");
    assert_eq!(message, json!("sit@L-7"));

    // `checkAppUpdate` carries `host.ui.call('showVersionPicker')`: a real
    // park/respond round-trip; the responder env and the script token are
    // combined inside JS.
    let responder = spawn_responder(
        "showVersionPicker",
        r#"{"env":"sit"}"#.to_string(),
        Duration::ZERO,
        Some("选择版本".to_string()),
    );
    let ui = parse(
        &harness
            .api
            .run("js_real_parity", "checkAppUpdate", r#"{"token":"U-9"}"#)
            .expect("run the host.ui.call contract through the real engine"),
        "uiCall",
    );
    let (request_id, payload) = responder
        .join()
        .expect("ui responder thread")
        .expect("ui responder");
    println!(
        "[real-lane:uiCall] request_id={request_id} kind={} message={} result={ui}",
        payload["kind"], payload["message"]
    );
    assert!(request_id.starts_with("ui-"));
    assert_eq!(payload["kind"], "showVersionPicker");
    assert_eq!(ui, json!({ "env": "sit", "tag": "ui:U-9" }));
}

#[test]
fn script_api_real_asset_example_js_parses_and_runs() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    clear_ui_state();

    // A fresh harness means a fresh temp root, pack store, SQLite DB and runtime
    // cache: no state leaks from the parity-fixture harness above.
    let source = example_asset_source();
    let harness = harness(
        "real-example-js",
        Duration::from_millis(500),
        Duration::from_millis(500),
    );
    harness
        .api
        .import(
            zip_with(&source, None, None),
            Some("js_example_real".to_string()),
        )
        .expect("the real assets/channels/example.js imports and parses");
    println!("[real-example-js:root] {}", harness.root.display());
    harness
        .api
        .set_config("js_example_real", HashMap::new())
        .expect("empty config snapshot");

    // example.js does not implement getConfig/sendMessage/ui.call; the dedicated
    // fixture above owns those three contracts.
    assert!(
        !source.contains("case 'getConfig'") && !source.contains("host.ui.call"),
        "example.js must not be claimed as the three-contract fixture"
    );

    // getAllApps is a real entry point: it calls host.network.get and maps the
    // response. The fake port answers 200 with an empty body, so the script's
    // `Array.isArray(res.data) ? res.data : []` yields an empty list.
    let value = parse(
        &harness
            .api
            .run("js_example_real", "getAllApps", "{}")
            .expect("the real example.js getAllApps entry point executes"),
        "getAllApps",
    );
    println!("[real-example-js:getAllApps] {value}");
    assert_eq!(value, json!([]));
}
