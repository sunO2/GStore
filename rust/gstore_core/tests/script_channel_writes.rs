//! Dart `JsChannel` update/persistence parity for the script driver.

mod support;

use gstore_core::channel::{ChannelDriver, ScriptChannel};
use gstore_core::dto::ChannelKey;
use gstore_core::ScriptChannelConfig;
use support::parity::{report, run, State};
use support::{fake_host, memory_store, sample_app};

const MISSING_UPDATE_DATA: &str = "err:脚本未返回更新数据（脚本未实现或数据获取失败）";
const MISSING_CONFIG: &str = "err:脚本未返回配置数据（脚本未实现或数据获取失败）";

#[test]
fn parity_do_update_persists_fallback_apps_and_preserves_rows() {
    let true_run = run("doUpdate", State::Success, true, false);
    report("doUpdate", "success/true", "true", &true_run);
    assert_eq!(true_run.stored, vec!["store.only"]);

    let fallback = run("doUpdate", State::DoUpdateFallback, true, false);
    report("doUpdate", "fallback/persist", "true", &fallback);
    assert_eq!(fallback.calls, 2, "doUpdate then getAllApps");
    assert_eq!(
        fallback.stored,
        vec!["app.dolphin", "app.other", "store.only"]
    );
    assert!(
        fallback.stored.contains(&"store.only".to_owned()),
        "never purge"
    );

    let fresh = run("doUpdate", State::DoUpdateFallback, false, false);
    report("doUpdate", "fallback/empty-store", "true", &fresh);
    assert_eq!(fresh.stored, vec!["app.dolphin", "app.other"]);

    for (label, state) in [
        ("null", State::Null),
        ("ok-false", State::OkFalse),
        ("throw", State::Throw),
        ("non-list", State::NonList),
    ] {
        let result = run("doUpdate", state, true, false);
        report("doUpdate", label, MISSING_UPDATE_DATA, &result);
        assert_eq!(
            result.stored,
            vec!["store.only"],
            "no partial writes on failure"
        );
    }

    let non_bool = run("doUpdate", State::NonBool, true, false);
    report("doUpdate", "non-bool", "true", &non_bool);
    assert_eq!(non_bool.stored, vec!["app.dolphin", "store.only"]);
}

#[test]
fn parity_call_config_is_a_script_result_not_a_cache_flag() {
    for (label, state) in [
        ("success", State::Success),
        ("null", State::Null),
        ("ok-false", State::OkFalse),
        ("throw", State::Throw),
        ("non-list", State::NonList),
        ("non-bool", State::NonBool),
    ] {
        let expected = if matches!(state, State::Success) {
            "9|http://proxy"
        } else {
            MISSING_CONFIG
        };
        let result = run("getConfig", state, true, false);
        report("getConfig", label, expected, &result);
    }
}

#[test]
fn parity_add_remove_use_the_bound_store() {
    let added = run("addApp", State::Null, false, false);
    report("addApp", "store-miss", "ok", &added);
    assert_eq!(added.stored, vec!["app.added"]);
    assert_eq!(added.calls, 0);

    let removed = run("removeApp", State::Null, true, false);
    report("removeApp", "store-hit", "ok", &removed);
    assert!(removed.stored.is_empty());
    assert_eq!(removed.calls, 0);

    let absent = run("removeApp", State::Null, false, false);
    report("removeApp", "missing-row", "ok", &absent);
    assert!(absent.stored.is_empty());
}

#[test]
fn parity_cache_methods_are_no_ops() {
    let cleared = run("clearCache", State::Null, true, false);
    report("clearCache", "any", "ok", &cleared);

    let size = run("getCacheSize", State::Null, true, false);
    report("getCacheSize", "any", "0", &size);
}

#[test]
fn parity_store_is_channel_scoped() {
    let host = fake_host();
    let store = memory_store();
    store.seed("js.left", vec![sample_app("left.only", "Left")]);
    store.seed("js.right", vec![sample_app("right.only", "Right")]);
    let script = "async function main() { return null; }";
    let left = ScriptChannel::new(
        ScriptChannelConfig::new(
            ChannelKey::new("js.left").expect("key"),
            script,
            host.clone(),
        )
        .with_store(store.clone()),
    )
    .expect("left");
    let right = ScriptChannel::new(
        ScriptChannelConfig::new(ChannelKey::new("js.right").expect("key"), script, host)
            .with_store(store.clone()),
    )
    .expect("right");

    let left_apps = left.get_all_apps(false).expect("left list");
    let right_apps = right.get_all_apps(false).expect("right list");
    println!(
        "INFO | getAllApps          | isolation              | expected=left.only | rust={}",
        left_apps[0].app_id
    );
    assert_eq!(left_apps.len(), 1);
    assert_eq!(right_apps.len(), 1);
    assert_eq!(left_apps[0].app_id, "left.only");
    assert_eq!(right_apps[0].app_id, "right.only");
    assert!(left.remove_app("right.only").is_ok());
    assert_eq!(
        store.rows("js.right").len(),
        1,
        "cross-channel delete is a no-op"
    );

    left.dispose().expect("left dispose");
    right.dispose().expect("right dispose");
}
