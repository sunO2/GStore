//! ScriptChannel parity against the real, unmodified example.js.

mod support;

use gstore_core::channel::{ChannelDriver, ScriptChannel};
use gstore_core::dto::{ChannelKey, ChannelKind};
use gstore_core::error::Error;
use gstore_core::ScriptChannelConfig;
use support::{fake_host, memory_store, sample_app, HostCall};

const EXAMPLE_JS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../assets/channels/example.js"
));

fn key(value: &str) -> ChannelKey {
    ChannelKey::new(value).expect("valid channel key")
}

#[test]
fn script_channel_example_meta_and_all_dispatched_methods() {
    let host = fake_host();
    let store = memory_store();
    store.seed(
        "js.example",
        vec![sample_app("org.example.dolphin", "Dolphin")],
    );
    let channel = ScriptChannel::new(
        ScriptChannelConfig::new(key("js.example"), EXAMPLE_JS, host.clone())
            .with_store(store.clone()),
    )
    .expect("example.js channel constructs");

    assert_eq!(channel.key().as_str(), "js.example");
    assert_eq!(channel.meta().kind, ChannelKind::JsLocal);
    assert_eq!(channel.meta().name, "示例渠道（模板）");
    assert_eq!(
        channel.meta().description,
        "脚本渠道模板：复制到应用 channels/ 目录后按需修改"
    );
    assert_eq!(channel.script_icon(), Some("template-icon"));
    assert!(channel.is_initialized().expect("initialized"));
    assert!(channel.check_available().expect("available"));
    channel.initialize().expect("idempotent initialize");

    let all = channel.get_all_apps(true).expect("getAllApps from store");
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].app_id, "org.example.dolphin");
    assert!(
        !host
            .calls()
            .iter()
            .any(|call| matches!(call, HostCall::Http { .. })),
        "getAllApps must never touch the script/network"
    );

    let search = channel.search_apps("dolphin", true).expect("searchApps");
    assert_eq!(search.len(), 1);
    assert_eq!(search[0].app_id, "org.example.dolphin");

    let info = channel
        .get_app_info("org.example.dolphin", true)
        .expect("getAppInfo");
    assert_eq!(info.name, "Dolphin");
    assert_eq!(info.des, "Flipper-powered browser");

    let detail = channel
        .get_app_detail("org.example.dolphin", true)
        .expect("getAppDetail");
    assert_eq!(detail.app_id, "org.example.dolphin");
    assert_eq!(detail.name, "Dolphin");
    assert_eq!(detail.version.as_deref(), Some("2.1.0"));
    assert_eq!(detail.developer.as_deref(), Some("Example Team"));
    assert_eq!(detail.package_name.as_deref(), Some("org.example.dolphin"));
    assert_eq!(
        detail.project_url.as_deref(),
        Some("https://example.test/dolphin")
    );
    assert_eq!(detail.channel, ChannelKind::JsLocal);
    assert!(detail.sections.is_empty());
    assert_eq!(detail.downloads.len(), 1);
    assert_eq!(detail.downloads[0].name, "dolphin-2.1.0.apk");
    assert!(detail.downloads[0].downloadable);

    let update = channel
        .check_app_update("org.example.dolphin")
        .expect("checkAppUpdate");
    assert_eq!(update.app_id, "org.example.dolphin");
    assert_eq!(update.package_name, "org.example.dolphin");
    assert_eq!(update.name, "Dolphin");
    assert_eq!(update.latest_version.as_deref(), Some("2.1.0"));
    assert!(update.latest_download.is_none());
    assert_eq!(update.detail.name, "Dolphin");

    assert!(!channel.check_update().expect("checkUpdate"));
    assert!(channel.do_update(None).expect("doUpdate fallback persists"));
    assert!(store.contains("js.example", "org.example.dolphin"));

    assert_eq!(
        channel.get_config(false).unwrap_err().message(),
        "脚本未返回配置数据（脚本未实现或数据获取失败）"
    );
    assert_eq!(
        channel.get_all_categories(true).unwrap_err().code(),
        "unsupported"
    );
    assert_eq!(
        channel
            .search_by_category("tools", true)
            .unwrap_err()
            .code(),
        "unsupported"
    );
    channel.add_app(&all[0]).expect("add_app persists");
    channel
        .remove_app("org.example.dolphin")
        .expect("remove_app deletes");
    assert!(!store.contains("js.example", "org.example.dolphin"));
    channel.clear_cache().expect("clearCache");
    assert_eq!(channel.get_cache_size().expect("cacheSize"), 0);

    let http_calls: Vec<HostCall> = host
        .calls()
        .into_iter()
        .filter(|call| matches!(call, HostCall::Http { .. }))
        .collect();
    assert!(!http_calls.is_empty(), "example.js used host.network.get");
    assert!(http_calls.iter().any(|call| matches!(
        call,
        HostCall::Http { channel, url }
            if channel == "js.example" && url.contains("/api/apps")
    )));

    channel.dispose().expect("first dispose");
    channel.dispose().expect("dispose is idempotent");
    assert!(!channel.is_initialized().expect("disposed"));
    assert_eq!(
        channel
            .get_app_info("org.example.dolphin", true)
            .unwrap_err()
            .code(),
        "internal"
    );
}

#[test]
fn script_channel_example_per_channel_isolation() {
    const ISOLATION_JS: &str = r#"
let __count = 0;
async function main(method, params) {
  if (method === 'getAppInfo') {
    __count = __count + 1;
    host.log.info('count=' + __count);
    return { ok: true, data: { appId: 'app-' + __count, name: 'App ' + __count } };
  }
  return null;
}
"#;
    let host = fake_host();
    let left = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.left"),
        ISOLATION_JS,
        host.clone(),
    ))
    .expect("left channel");
    let right = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.right"),
        ISOLATION_JS,
        host.clone(),
    ))
    .expect("right channel");

    for expected in ["App 1", "App 2"] {
        let app = left.get_app_info("app", true).expect("left app");
        assert_eq!(app.name, expected);
    }
    for expected in ["App 1", "App 2"] {
        let app = right.get_app_info("app", true).expect("right app");
        assert_eq!(app.name, expected);
    }

    let logs = |channel: &str| -> Vec<String> {
        host.calls()
            .into_iter()
            .filter_map(|call| match call {
                HostCall::Log {
                    channel: logged,
                    message,
                } if logged == channel => Some(message),
                _ => None,
            })
            .collect()
    };
    assert_eq!(logs("js.left"), vec!["count=1", "count=2"]);
    assert_eq!(logs("js.right"), vec!["count=1", "count=2"]);

    left.dispose().expect("left dispose");
    right.dispose().expect("right dispose");
}

#[test]
fn script_channel_example_rejects_pack_key_mismatch() {
    let result = ScriptChannel::new(
        ScriptChannelConfig::new(key("js.example"), EXAMPLE_JS, fake_host())
            .with_pack_key(key("js.other")),
    );
    assert!(matches!(result, Err(Error::InvalidArgument(message)) if message.contains("pack key")));
}

#[test]
fn script_channel_unsupported_is_typed() {
    let channel = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.example"),
        EXAMPLE_JS,
        fake_host(),
    ))
    .expect("example.js channel constructs");

    let search = channel
        .search_by_category("tools", true)
        .expect_err("search_by_category is unsupported");
    assert_eq!(search.code(), "unsupported");
    assert_eq!(
        search.message(),
        "channel does not support search_by_category"
    );

    let categories = channel
        .get_all_categories(true)
        .expect_err("get_all_categories is unsupported");
    assert_eq!(categories.code(), "unsupported");
    assert_eq!(
        categories.message(),
        "channel does not support get_all_categories"
    );

    channel.dispose().expect("dispose");
}
