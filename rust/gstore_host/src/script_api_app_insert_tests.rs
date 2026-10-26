//! `ScriptApi::add_app`: one app inserted into a pack's `channel_apps` rows is
//! immediately readable through `stored_apps`, and bad input is a typed error.

use std::time::Duration;

use gstore_core::dto::AppSummary;

use crate::script_api_test_support::{harness, zip_with};
use crate::TEST_SERIAL;

fn fast_harness(tag: &str) -> crate::script_api_test_support::Harness {
    harness(tag, Duration::from_millis(200), Duration::from_millis(100))
}

fn app(app_id: &str) -> AppSummary {
    AppSummary {
        app_id: app_id.to_string(),
        package_name: Some(format!("{app_id}.pkg")),
        name: "Inserted".to_string(),
        user: "team".to_string(),
        repositories: "repo".to_string(),
        icon: "icon".to_string(),
        des: "desc".to_string(),
        readme: None,
        category: Some(vec!["Tools".to_string()]),
        extra: None,
    }
}

#[test]
fn script_api_add_app_roundtrips_through_stored_apps() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("app-insert");
    harness
        .api
        .import(
            zip_with("function main(){ return null; }", None, None),
            Some("js_insert".to_string()),
        )
        .expect("import pack");

    // Given: no rows saved yet.
    let before = harness.api.stored_apps("js_insert").expect("stored apps");
    assert!(
        !before.contains("app.one"),
        "precondition: no saved rows: {before}"
    );

    // When: one app is inserted into the pack's rows.
    harness
        .api
        .add_app("js_insert", app("app.one"))
        .expect("insert app");

    // Then: stored_apps reads back exactly what was inserted.
    let stored = harness.api.stored_apps("js_insert").expect("stored apps");
    assert!(
        stored.contains("app.one"),
        "the insert must be readable through stored_apps: {stored}"
    );
    assert!(
        stored.contains("Inserted"),
        "the row name must round-trip: {stored}"
    );
}

#[test]
fn script_api_add_app_rejects_unknown_empty_key_and_bad_app() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("app-insert-errors");
    harness
        .api
        .import(
            zip_with("function main(){ return null; }", None, None),
            Some("js_insert".to_string()),
        )
        .expect("import pack");

    // Given/When/Then: an unknown pack key is a typed error, not an orphan row.
    let unknown = harness
        .api
        .add_app("js_missing", app("app.one"))
        .expect_err("unknown key must fail");
    assert!(
        unknown.contains("pack_not_found"),
        "unknown key must be a typed pack_not_found: {unknown}"
    );

    // An empty key is a typed invalid_argument.
    let empty = harness
        .api
        .add_app("   ", app("app.one"))
        .expect_err("empty key must fail");
    assert!(
        empty.contains("invalid_argument"),
        "empty key must be a typed invalid_argument: {empty}"
    );

    // An app with an empty id is a typed invalid_argument.
    let bad = harness
        .api
        .add_app("js_insert", app("   "))
        .expect_err("bad app must fail");
    assert!(
        bad.contains("invalid_argument"),
        "empty app_id must be a typed invalid_argument: {bad}"
    );
}
