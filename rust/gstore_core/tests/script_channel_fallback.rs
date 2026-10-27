//! Store fallbacks and typed failures for ScriptChannel (Dart `JsChannel`).

mod support;

use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, ScriptChannel};
use gstore_core::dto::ChannelKey;
use gstore_core::ScriptChannelConfig;
use support::{fake_host, memory_store, sample_app, MemoryStore};

const NULL_JS: &str = "async function main() { return null; }";
const MISSING_MAIN_JS: &str = "var notAnEntryPoint = 1;";

const ERROR_ENVELOPE_JS: &str = r#"
async function main() {
  return { ok: false, error: 'boom' };
}
"#;

const THROWING_JS: &str = r#"
async function main() {
  throw new Error('kaboom');
}
"#;

const WRONG_TYPE_JS: &str = r#"
async function main(method) {
  if (method === 'checkUpdate') return { ok: true, data: 'yes' };
  return { ok: true, data: 'not-a-list' };
}
"#;

const MISSING_DETAIL: &str = "脚本未返回详情数据（脚本未实现或数据获取失败）";
const MISSING_UPDATE: &str = "脚本未返回更新信息且渠道库无该应用";
const MISSING_UPDATE_DATA: &str = "脚本未返回更新数据（脚本未实现或数据获取失败）";
const MISSING_CONFIG: &str = "脚本未返回配置数据（脚本未实现或数据获取失败）";
const MISSING_SEARCH: &str = "脚本未实现 searchApps 和 getAllApps";

fn key(value: &str) -> ChannelKey {
    ChannelKey::new(value).expect("valid channel key")
}

fn seeded() -> Arc<MemoryStore> {
    let store = memory_store();
    store.seed("js.fallback", vec![sample_app("store.only", "Store Only")]);
    store
}

fn channel(script: &str, store: Option<Arc<MemoryStore>>) -> ScriptChannel {
    let mut config = ScriptChannelConfig::new(key("js.fallback"), script, fake_host());
    if let Some(store) = store {
        config = config.with_store(store);
    }
    ScriptChannel::new(config).expect("script channel constructs")
}

#[test]
fn script_channel_null_degrades_to_the_saved_channel_rows() {
    let store = seeded();
    let channel = channel(NULL_JS, Some(store));

    let apps = channel.get_all_apps(true).expect("store getAllApps");
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].app_id, "store.only");

    let info = channel.get_app_info("store.only", true).expect("store hit");
    assert_eq!(info.name, "Store Only");
    assert_eq!(
        channel.get_app_info("missing", true).unwrap_err().code(),
        "not_found"
    );

    assert_eq!(
        channel
            .get_app_detail("store.only", true)
            .unwrap_err()
            .message(),
        MISSING_DETAIL
    );
    assert_eq!(
        channel.search_apps("store", true).unwrap_err().message(),
        MISSING_SEARCH
    );

    let update = channel
        .check_app_update("store.only")
        .expect("summary update");
    assert_eq!(update.app_id, "store.only");
    assert_eq!(update.package_name, "store.only");
    assert!(update.latest_version.is_none());
    assert_eq!(
        channel.check_app_update("missing").unwrap_err().message(),
        MISSING_UPDATE
    );

    assert!(!channel.check_update().expect("no update by default"));
    assert_eq!(
        channel.do_update(None).unwrap_err().message(),
        MISSING_UPDATE_DATA
    );
    assert_eq!(
        channel.get_config(false).unwrap_err().message(),
        MISSING_CONFIG
    );

    channel.dispose().expect("dispose");
}

#[test]
fn script_channel_missing_main_uses_the_store() {
    let store = seeded();
    let channel = channel(MISSING_MAIN_JS, Some(store));
    let apps = channel.get_all_apps(false).expect("store list");
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].app_id, "store.only");
    channel.dispose().expect("dispose");
}

#[test]
fn script_channel_without_store_keeps_script_results_and_rejects_writes() {
    let channel = channel(MISSING_MAIN_JS, None);
    assert!(channel.get_all_apps(false).expect("empty store").is_empty());
    assert_eq!(
        channel
            .add_app(&sample_app("app", "App"))
            .unwrap_err()
            .code(),
        "unsupported"
    );
    assert_eq!(channel.remove_app("app").unwrap_err().code(), "unsupported");
    channel.dispose().expect("dispose");
}

#[test]
fn script_channel_error_envelope_and_throw_are_no_script_results() {
    for script in [ERROR_ENVELOPE_JS, THROWING_JS] {
        let store = seeded();
        let channel = channel(script, Some(store));

        assert_eq!(
            channel.get_all_apps(false).expect("store list")[0].app_id,
            "store.only"
        );
        assert_eq!(
            channel
                .get_app_info("store.only", true)
                .expect("store hit")
                .name,
            "Store Only"
        );
        assert_eq!(
            channel
                .get_app_detail("store.only", true)
                .unwrap_err()
                .message(),
            MISSING_DETAIL
        );
        assert!(!channel.check_update().expect("false by default"));
        assert_eq!(
            channel.do_update(None).unwrap_err().message(),
            MISSING_UPDATE_DATA
        );
        assert_eq!(
            channel.get_config(false).unwrap_err().message(),
            MISSING_CONFIG
        );

        channel.dispose().expect("dispose");
    }
}

#[test]
fn script_channel_wrong_types_degrade_instead_of_serialization_errors() {
    let channel = channel(WRONG_TYPE_JS, None);
    assert_eq!(
        channel.search_apps("dolphin", false).unwrap_err().message(),
        MISSING_SEARCH
    );
    assert!(!channel.check_update().expect("non-boolean is false"));
    assert_eq!(
        channel.get_config(false).unwrap_err().message(),
        MISSING_CONFIG
    );
    channel.dispose().expect("dispose");
}
