//! `ScriptApi::add_app`: one app inserted into a pack's `channel_apps` rows is
//! immediately readable through `stored_apps`, and bad input is a typed error.

use std::path::{Path, PathBuf};
use std::time::Duration;

use gstore_core::channel::{PackPolicy, PackStore};
use gstore_core::db::{core_db_path, DbHandle};
use gstore_core::dto::AppSummary;

use crate::script_api_test_support::{harness, reopen, zip_with, zip_with_extra};
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

fn read_only(data_dir: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open_with_flags(
        core_db_path(data_dir),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open core db read-only")
}

fn pack_row_key(data_dir: &Path) -> String {
    read_only(data_dir)
        .query_row("SELECT key FROM channel_packs", [], |row| row.get(0))
        .expect("channel_packs.key")
}

fn app_row_key(data_dir: &Path, app_id: &str) -> String {
    read_only(data_dir)
        .query_row(
            "SELECT channel_key FROM channel_apps WHERE app_id=?1",
            [app_id],
            |row| row.get(0),
        )
        .expect("channel_apps.channel_key")
}

fn probe_root(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "gstore-strict-probe-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("create probe root");
    root
}

/// True when a Strict-only store rejects `bytes` (so `ScriptApi::import` could
/// only have accepted them through the legacy-permissive fallback).
fn strict_rejects(tag: &str, bytes: &[u8]) -> bool {
    let root = probe_root(tag);
    let db = DbHandle::open(&root.join("data")).expect("probe db");
    let store = PackStore::new(root.join("packs"), db).with_policy(PackPolicy::Strict);
    let zip_path = root.join("probe.zip");
    std::fs::write(&zip_path, bytes).expect("write probe zip");
    let rejected = store.import_pack(&zip_path).is_err();
    let _ = std::fs::remove_dir_all(&root);
    rejected
}

#[test]
fn script_api_lane_save_persists_across_reopen_legacy_pack() {
    let _serial = TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let harness = fast_harness("lane-persist-legacy");

    // A pack the user's import took the legacy-permissive route on: the extra
    // root entry is a strict `pack_layout` error but is ignored by legacy.
    let bytes = zip_with_extra(
        "function main(){ return null; }",
        &[("README.txt", b"legacy pack")],
    );
    assert!(
        strict_rejects("lane-persist-legacy", &bytes),
        "precondition: strict decoding must reject this pack (legacy route taken)"
    );

    let info = harness
        .api
        .import(bytes, Some("js_legacy".to_string()))
        .expect("import legacy pack");
    assert_eq!(
        info.key, "js_legacy",
        "the imported pack key must be js_<stem>"
    );

    let data = harness.root.join("data");
    assert_eq!(
        pack_row_key(&data),
        "js_legacy",
        "channel_packs.key must be the lane code"
    );
    println!(
        "KEY HOP: ScriptPackInfo.key={:?} channel_packs.key={:?}",
        info.key,
        pack_row_key(&data)
    );

    // Given: no rows saved yet.
    let before = harness.api.stored_apps("js_legacy").expect("stored apps");
    assert!(!before.contains("com.legacy"), "precondition: no saved rows");

    // When: the discovery save inserts one app under the lane code.
    harness
        .api
        .add_app("js_legacy", app("com.legacy"))
        .expect("insert app");

    // Then: readable immediately, and the stored key form matches the write.
    let stored = harness.api.stored_apps("js_legacy").expect("stored apps");
    assert!(
        stored.contains("com.legacy"),
        "the insert must be readable through stored_apps: {stored}"
    );
    assert_eq!(
        app_row_key(&data, "com.legacy"),
        "js_legacy",
        "channel_apps.channel_key must equal the lane code the UI reads"
    );
    println!(
        "KEY HOP: add_app key={:?} channel_apps.channel_key={:?} app_id={:?}",
        "js_legacy",
        app_row_key(&data, "com.legacy"),
        "com.legacy"
    );

    // Then: a brand-new handle over the same files still sees the row (restart).
    let reopened = reopen(&harness);
    let after_restart = reopened
        .stored_apps("js_legacy")
        .expect("stored apps after reopen");
    assert!(
        after_restart.contains("com.legacy"),
        "the saved row must survive a restart: {after_restart}"
    );
}
