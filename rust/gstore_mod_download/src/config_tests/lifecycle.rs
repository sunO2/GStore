//! Subscribe/read ordering, malformed input, vtable writes, fallback, PublicRead.

use gstore_contract::abi::GStoreConfigApiV1;
use serde_json::json;

use super::harness::*;
use super::mock::MockHost;
use crate::config;

#[test]
fn change_during_subscribe_window_is_not_lost() {
    let _guard = test_lock();
    crate::reset_for_test();
    let host: &'static MockHost = Box::leak(Box::new(MockHost::new()));
    host.queue_during_subscribe("download", config::KEY_MAX_CONCURRENT, json!(2));
    let vtable = Box::leak(Box::new(host.vtable()));
    let _api = register_with(vtable as *const GStoreConfigApiV1);

    let id = create_instance();
    let log = host.call_log();
    let first_subscribe = log.iter().position(|c| c.starts_with("subscribe:"));
    let first_get = log.iter().position(|c| c.starts_with("get:"));
    assert!(
        matches!((first_subscribe, first_get), (Some(s), Some(g)) if s < g),
        "must subscribe before the initial read: {log:?}"
    );

    assert_eq!(
        stats(id)["maxConcurrent"],
        2,
        "change committed during the subscribe window must survive"
    );
}

#[test]
fn malformed_or_out_of_range_value_keeps_previous() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let id = create_instance();

    host.set_value("download", config::KEY_MAX_CONCURRENT, json!(5));
    assert_eq!(stats(id)["maxConcurrent"], 5);

    host.set_value(
        "download",
        config::KEY_MAX_CONCURRENT,
        json!("not-a-number"),
    );
    assert_eq!(stats(id)["maxConcurrent"], 5, "wrong type keeps previous");

    host.set_value("download", config::KEY_MAX_CONCURRENT, json!(99));
    assert_eq!(stats(id)["maxConcurrent"], 5, "out-of-range keeps previous");

    host.set_value("download", config::KEY_MULTI_SEGMENT_ENABLED, json!("nope"));
    assert_eq!(
        stats(id)["multiSegmentEnabled"],
        true,
        "wrong type keeps previous boolean"
    );
}

#[test]
fn download_config_writes_through_vtable() {
    let _guard = test_lock();
    crate::reset_for_test();
    let (host, _api) = mount();
    let id = create_instance();

    let reply = call(
        id,
        "download.config",
        r#"{"maxConcurrent":2,"connections":6,"speedLimitBps":0}"#,
    )
    .expect("download.config succeeds");

    assert_eq!(
        host.stored("download", config::KEY_MAX_CONCURRENT),
        Some(json!(2)),
        "write must land in the authoritative store"
    );
    assert_eq!(
        host.stored("download", config::KEY_DEFAULT_CONNECTIONS),
        Some(json!(6))
    );
    assert_eq!(
        host.stored("download", config::KEY_SPEED_LIMIT_BPS),
        Some(json!(0))
    );
    assert_eq!(reply["maxConcurrent"], 2);
    assert_eq!(reply["connections"], 6);
    assert_eq!(stats(id)["effectiveConnections"], 6);
}

#[test]
fn absent_vtable_falls_back_to_built_in_defaults() {
    let _guard = test_lock();
    crate::reset_for_test();
    let _host = mount_without_vtable();
    let id = create_instance();

    let s = stats(id);
    assert_eq!(s["maxConcurrent"], 3);
    assert_eq!(s["multiSegmentEnabled"], true);
    assert_eq!(s["effectiveConnections"], 4);
    assert_eq!(s["proxyConfigured"], false);

    let reply = call(id, "download.config", r#"{"maxConcurrent":2}"#)
        .expect("legacy in-memory config still works");
    assert_eq!(reply["maxConcurrent"], 2);
}

#[test]
fn public_read_proxy_url_is_read_but_not_subscribed() {
    let _guard = test_lock();
    crate::reset_for_test();
    let host: &'static MockHost = Box::leak(Box::new(MockHost::new()));
    host.prime(
        config::MODULE_NETWORK,
        config::KEY_PROXY_URL,
        json!("https://gh-proxy.org/"),
    );
    let vtable = Box::leak(Box::new(host.vtable()));
    let _api = register_with(vtable as *const GStoreConfigApiV1);
    let id = create_instance();

    assert_eq!(stats(id)["proxyConfigured"], true);
    assert!(host.call_log().iter().any(|c| c == "get:network:proxy_url"));
    assert!(
        host.subscriptions()
            .iter()
            .all(|(module, key)| module == "download" && key.is_none()
                || key.as_deref() == Some(config::KEY_MULTI_SEGMENT_ENABLED)),
        "must not subscribe to foreign modules"
    );
}
