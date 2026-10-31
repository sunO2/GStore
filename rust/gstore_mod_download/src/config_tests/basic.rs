//! Whole-module and exact-key delivery, stats projection, ABI declaration.

use serde_json::json;

use super::harness::*;
use crate::config;

#[test]
fn declares_min_host_abi_five() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (_host, api) = mount();
    assert_eq!(api.min_host_abi, 5, "module must declare min_host_abi=5");
    assert!(
        !gstore_contract::abi::host_abi_satisfies(api.min_host_abi, 4),
        "a v4 host must reject this module at probe time"
    );
}

#[test]
fn host_config_changes_next_stats_without_restart() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let id = create_instance();

    let before = stats(id);
    assert_eq!(before["maxConcurrent"], 3);
    assert_eq!(before["multiSegmentEnabled"], true);
    assert_eq!(before["effectiveConnections"], 4);

    host.set_value("download", config::KEY_MAX_CONCURRENT, json!(2));
    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!(false));
    host.set_value("download", config::KEY_DEFAULT_CONNECTIONS, json!(8));

    let after = stats(id);
    assert_eq!(after["maxConcurrent"], 2);
    assert_eq!(after["multiSegmentEnabled"], false);
    assert_eq!(after["defaultConnections"], 8);
    assert_eq!(
        after["effectiveConnections"], 1,
        "multi-segment off must force a single connection"
    );
}

#[test]
fn multi_segment_off_forces_single_connection_regardless_of_default() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let id = create_instance();

    host.set_value("download", config::KEY_DEFAULT_CONNECTIONS, json!(9));
    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!(true));
    assert_eq!(stats(id)["effectiveConnections"], 9);

    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!(false));
    assert_eq!(stats(id)["effectiveConnections"], 1);

    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!(true));
    assert_eq!(
        stats(id)["effectiveConnections"],
        9,
        "re-enabling restores the remembered default_connections"
    );
}

#[test]
fn theme_change_does_not_invoke_download_callback() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let _id = create_instance();

    let before = host.delivered_count();
    host.set_value("theme", "mode", json!(2));
    assert_eq!(
        host.delivered_count(),
        before,
        "a theme.* change must not reach the download callback"
    );
    assert!(
        host.subscriptions()
            .iter()
            .all(|(module, _)| module == "download"),
        "module must only subscribe to its own module"
    );
}

#[test]
fn whole_module_and_exact_key_subscriptions_both_deliver() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let _id = create_instance();

    let subs = host.subscriptions();
    assert_eq!(subs.len(), 2, "expected whole-module + exact-key");
    assert!(subs.iter().any(|(m, k)| m == "download" && k.is_none()));
    assert!(subs
        .iter()
        .any(|(m, k)| m == "download" && k.as_deref() == Some(config::KEY_MULTI_SEGMENT_ENABLED)));
    assert!(subs.iter().all(|(m, _)| m == "download"));

    let before = host.delivered_count();
    host.set_value("download", config::KEY_MAX_RETRIES, json!(1));
    assert_eq!(
        host.delivered_count() - before,
        1,
        "only the whole-module subscription matches max_retries"
    );

    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!(false));
    assert_eq!(
        host.delivered_count() - before,
        3,
        "multi_segment.enabled is delivered by both subscriptions"
    );
}

#[test]
fn source_never_reads_unregistered_segment_keys() {
    // Built at runtime so a grep for the literal names finds nothing anywhere.
    let banned_a = ["segment_", "size_bytes"].concat();
    let banned_b = ["max_", "segments"].concat();
    for (name, source) in [
        ("lib.rs", include_str!("../lib.rs")),
        ("config/mod.rs", include_str!("../config/mod.rs")),
        ("config/keys.rs", include_str!("../config/keys.rs")),
        ("config/model.rs", include_str!("../config/model.rs")),
        ("scheduler.rs", include_str!("../scheduler.rs")),
        ("store.rs", include_str!("../store.rs")),
        ("engine.rs", include_str!("../engine.rs")),
        ("model.rs", include_str!("../model.rs")),
    ] {
        assert!(
            !source.contains(&banned_a),
            "{name} must not read {banned_a}"
        );
        assert!(
            !source.contains(&banned_b),
            "{name} must not read {banned_b}"
        );
    }
}
