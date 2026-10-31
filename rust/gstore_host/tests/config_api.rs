//! Todo 8 acceptance tests for the FRB `ConfigApi` (C1 / C3 / C9 / C18).
//!
//! These live in their own integration-test process so the process-global
//! store cannot be replaced by the many `CoreApi::init` unit tests that run in
//! parallel in the library test binary. Tests inside this binary still share
//! the global, so they serialize on [`SERIAL`].

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use gstore_host::bridge::{
    events_recording_config_for_test, reset_config_store_for_test,
    watch_recording_config_for_test, ConfigApi, ConfigChangeDto, ConfigVerifyEntryDto, CoreApi,
    HostInspector, RecordingConfigSink,
};
use serde_json::{json, Value};

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|error| error.into_inner())
}

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "gstore_config_api_{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    fn init(&self) -> CoreApi {
        CoreApi::init(
            self.root.join("data").to_string_lossy().into_owned(),
            self.root.join("files").to_string_lossy().into_owned(),
            self.root.join("cache").to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn value(text: &str) -> Value {
    serde_json::from_str(text).expect("value is JSON")
}

fn init_api(scratch: &Scratch) -> (CoreApi, ConfigApi) {
    let core = scratch.init();
    let config = ConfigApi::init().expect("ConfigApi::init");
    (core, config)
}

fn watch(
    module: &str,
    key: Option<&str>,
    sink: &RecordingConfigSink,
) -> Result<(), String> {
    watch_recording_config_for_test(module.to_string(), key.map(str::to_string), sink.clone())
}

fn changes_of(sink: &RecordingConfigSink) -> Vec<ConfigChangeDto> {
    sink.received()
}

#[test]
fn config_api_set_get_masked_roundtrip_and_typed_errors() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("roundtrip");
    let (_core, config) = init_api(&scratch);

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(5).to_string(),
            "user".to_string(),
        )
        .expect("set max_concurrent");
    assert_eq!(
        value(&config
            .get("download".to_string(), "max_concurrent".to_string(), true)
            .expect("masked get")),
        json!(5)
    );

    config
        .set(
            "webdav".to_string(),
            "password".to_string(),
            json!("hunter2").to_string(),
            "user".to_string(),
        )
        .expect("set password");
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), true)
            .expect("masked secret get")),
        json!("***")
    );
    assert_eq!(
        value(&config
            .get("webdav".to_string(), "password".to_string(), false)
            .expect("raw secret get")),
        json!("hunter2")
    );

    let unknown = config
        .get("download".to_string(), "no_such_key".to_string(), true)
        .expect_err("unknown key must fail");
    assert!(
        unknown.contains("config_unknown_key"),
        "expected typed unknown-key error, got {unknown}"
    );

    let bad_json = config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            "{not json".to_string(),
            "user".to_string(),
        )
        .expect_err("malformed JSON must fail");
    assert!(
        bad_json.contains("config_invalid_json"),
        "expected JSON parse error, got {bad_json}"
    );

    let bad_source = config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(4).to_string(),
            "nope".to_string(),
        )
        .expect_err("unknown source must fail");
    assert!(
        bad_source.contains("config_invalid_source"),
        "expected invalid-source error, got {bad_source}"
    );

    reset_config_store_for_test();
}

#[test]
fn config_api_two_watchers_same_filter_both_receive_and_survive_sibling_failure() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("two_watchers");
    let (_core, config) = init_api(&scratch);

    let first = RecordingConfigSink::new();
    let second = RecordingConfigSink::new();
    watch("download", Some("max_concurrent"), &first).expect("watch first");
    watch("download", Some("max_concurrent"), &second).expect("watch second");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(7).to_string(),
            "user".to_string(),
        )
        .expect("first set");
    assert_eq!(first.count(), 1, "first listener must receive");
    assert_eq!(second.count(), 1, "second listener must receive");
    assert_eq!(changes_of(&first)[0].wire_key, "download.max_concurrent");

    second.set_failing(true);
    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(8).to_string(),
            "user".to_string(),
        )
        .expect("second set");
    assert_eq!(first.count(), 2, "surviving listener keeps receiving");
    assert_eq!(second.count(), 1, "failing sink must be pruned");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(9).to_string(),
            "user".to_string(),
        )
        .expect("third set");
    assert_eq!(first.count(), 3, "pruned sink must not affect others");
    assert_eq!(second.count(), 1, "pruned sink stays pruned");

    reset_config_store_for_test();
}

#[test]
fn config_api_whole_module_watch_ignores_other_modules() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("filtered");
    let (_core, config) = init_api(&scratch);

    let sink = RecordingConfigSink::new();
    watch("download", None, &sink).expect("watch download module");

    config
        .set(
            "theme".to_string(),
            "mode".to_string(),
            json!(2).to_string(),
            "user".to_string(),
        )
        .expect("set theme");
    assert_eq!(sink.count(), 0, "theme.* must not reach a download watch");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(6).to_string(),
            "user".to_string(),
        )
        .expect("set download");
    assert_eq!(sink.count(), 1, "download.* must reach the module watch");
    assert_eq!(changes_of(&sink)[0].wire_key, "download.max_concurrent");

    reset_config_store_for_test();
}

#[test]
fn config_api_verify_meta_and_export_roundtrip() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("export_verify_meta");
    let (_core, config) = init_api(&scratch);

    config
        .set(
            "webdav".to_string(),
            "password".to_string(),
            json!("hunter2").to_string(),
            "user".to_string(),
        )
        .expect("set password");
    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(5).to_string(),
            "user".to_string(),
        )
        .expect("set max_concurrent");

    let export = config.export().expect("export");
    let secret = export
        .entries
        .iter()
        .find(|entry| entry.wire_key == "webdav.password")
        .expect("password present in export");
    assert_eq!(
        value(&secret.value_json),
        json!("hunter2"),
        "export is the raw backup surface"
    );

    let snapshots = config.snapshots(Some("webdav".to_string())).expect("snapshots");
    let password = snapshots
        .iter()
        .find(|snapshot| snapshot.key == "password")
        .expect("password snapshot");
    assert_eq!(password.value_json.as_deref().map(value), Some(json!("***")));

    let entries = config.list(Some("webdav".to_string())).expect("list webdav");
    let listed = entries
        .iter()
        .find(|entry| entry.key == "password")
        .expect("password entry metadata");
    assert_eq!(value(&listed.value_json), json!("***"));
    assert_eq!(listed.visibility, "secret");
    assert!(listed.sensitive);

    let migration = config.ensure_migrated().expect("ensure_migrated");
    assert!(migration.schema_ready, "hydration must report schema readiness");
    assert!(
        !migration.migrated,
        "Todo 8 performs no legacy migration; migrated must stay false"
    );

    let verify = config
        .verify(vec![
            ConfigVerifyEntryDto {
                module: "webdav".to_string(),
                key: "password".to_string(),
                value_json: json!("hunter2").to_string(),
            },
            ConfigVerifyEntryDto {
                module: "download".to_string(),
                key: "max_concurrent".to_string(),
                value_json: json!(5).to_string(),
            },
        ])
        .expect("verify");
    assert_eq!(verify.total, 2);
    assert_eq!(verify.matched, 2);
    assert!(verify.all_matched);

    config
        .meta_set("task8_marker".to_string(), json!({"ok": true}).to_string())
        .expect("meta_set");
    assert_eq!(
        config.meta_get("task8_marker".to_string()).expect("meta_get"),
        Some(json!({"ok": true}).to_string())
    );
    assert_eq!(
        config.meta_get("absent".to_string()).expect("missing meta"),
        None
    );
    assert!(
        config
            .meta_set("revision".to_string(), "1".to_string())
            .is_err(),
        "the store-owned revision meta key must be rejected"
    );

    reset_config_store_for_test();
}

#[test]
fn config_api_uses_the_same_store_as_core_api() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("shared_store");
    let (core, config) = init_api(&scratch);

    assert!(
        core.shares_config_store_with_global_for_test(),
        "finish_init must install its own store in the process global"
    );

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(10).to_string(),
            "user".to_string(),
        )
        .expect("set through ConfigApi");
    assert_eq!(
        value(&core
            .config_value_for_test("download".to_string(), "max_concurrent".to_string())
            .expect("read through CoreApi's store")),
        json!(10),
        "a write through the FRB face is visible through CoreApi's own Arc"
    );

    reset_config_store_for_test();
}

#[test]
fn config_api_second_core_init_replaces_instead_of_reusing_a_stale_store() {
    let _guard = serial();
    reset_config_store_for_test();
    let first_scratch = Scratch::new("first_init");
    let second_scratch = Scratch::new("second_init");

    let first = first_scratch.init();
    let first_config = ConfigApi::init().expect("first ConfigApi");
    first_config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(9).to_string(),
            "user".to_string(),
        )
        .expect("write first store");

    // A second init in the same process replaces the global while the first
    // handle stays alive (C1).
    let second = second_scratch.init();
    let second_config = ConfigApi::init().expect("second ConfigApi");

    assert!(
        !first.shares_config_store_with_global_for_test(),
        "the first handle must no longer be the global store"
    );
    assert!(
        second.shares_config_store_with_global_for_test(),
        "the second handle must be the global store"
    );
    assert_eq!(
        value(&second_config
            .get("download".to_string(), "max_concurrent".to_string(), true)
            .expect("second store read")),
        json!(3),
        "the second store must not see the first store's value"
    );
    assert_eq!(
        value(&first
            .config_value_for_test("download".to_string(), "max_concurrent".to_string())
            .expect("first store read")),
        json!(9),
        "the first store still owns its own value"
    );

    reset_config_store_for_test();
}

#[test]
fn config_api_reset_bridges_stops_delivery() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("reset_bridges");
    let (_core, config) = init_api(&scratch);

    let sink = RecordingConfigSink::new();
    watch("download", None, &sink).expect("watch download module");

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(3).to_string(),
            "user".to_string(),
        )
        .expect("before reset");
    assert_eq!(sink.count(), 1);

    HostInspector::new().reset_bridges();

    config
        .set(
            "download".to_string(),
            "max_concurrent".to_string(),
            json!(4).to_string(),
            "user".to_string(),
        )
        .expect("after reset");
    assert_eq!(sink.count(), 1, "reset_bridges must clear config sinks");

    reset_config_store_for_test();
}

#[test]
fn config_api_global_stream_covers_every_registered_module() {
    let _guard = serial();
    reset_config_store_for_test();
    let scratch = Scratch::new("global_all_modules");
    let (_core, config) = init_api(&scratch);

    let global = RecordingConfigSink::new();
    events_recording_config_for_test(global.clone());
    let proxy = RecordingConfigSink::new();
    watch("proxy", None, &proxy).expect("watch proxy module");

    let mut distinct_modules = std::collections::BTreeSet::new();
    let mut expected_events = 0usize;
    for entry in gstore_core::config::schema::entries() {
        if !distinct_modules.insert(entry.key.module().to_string()) {
            continue;
        }
        expected_events += 1;
        config
            .set(
                entry.key.module().to_string(),
                entry.key.key().to_string(),
                serde_json::to_string(&entry.default_json).unwrap(),
                "user".to_string(),
            )
            .unwrap_or_else(|error| {
                panic!("set default for {} failed: {error}", entry.key.wire())
            });
    }

    assert!(
        distinct_modules.len() > 11,
        "registry must span more than the eleven toggle namespaces, got {distinct_modules:?}"
    );
    let delivered: std::collections::BTreeSet<String> = global
        .received()
        .iter()
        .map(|change| change.module.clone())
        .collect();
    assert_eq!(
        delivered, distinct_modules,
        "global stream must receive every distinct registry module"
    );
    assert_eq!(global.count(), expected_events);

    assert!(
        proxy.received().iter().all(|change| change.module == "proxy"),
        "per-filter watch must not leak foreign modules"
    );
    assert_eq!(
        proxy.received().len(),
        1,
        "exactly the one proxy key set in this test must reach the proxy filter"
    );

    reset_config_store_for_test();
}
