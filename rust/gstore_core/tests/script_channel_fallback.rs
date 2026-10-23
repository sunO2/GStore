//! Fallback, data-preservation, and typed-error contracts for ScriptChannel.

mod support;

use std::sync::Arc;

use gstore_core::channel::{ChannelConfig, ChannelDriver, InMemoryChannelDriver, ScriptChannel};
use gstore_core::dto::{AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use gstore_core::ScriptChannelConfig;
use support::fake_host;

const NULL_JS: &str = r#"
async function main(method, params) {
  return null;
}
"#;

const MISSING_MAIN_JS: &str = "var notAnEntryPoint = 1;";

const ERROR_ENVELOPE_JS: &str = r#"
async function main(method, params) {
  return { ok: false, error: 'boom' };
}
"#;

const WRONG_TYPE_JS: &str = r#"
async function main(method, params) {
  if (method === 'checkUpdate') return { ok: true, data: 'yes' };
  return { ok: true, data: 'not-a-list' };
}
"#;

const THROWING_JS: &str = r#"
async function main(method, params) {
  throw new Error('kaboom');
}
"#;

fn key(value: &str) -> ChannelKey {
    ChannelKey::new(value).expect("valid channel key")
}

fn meta() -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::JsLocal,
        name: "fallback".to_string(),
        description: "fallback driver".to_string(),
        enabled: true,
        priority: 0,
        support_offline: false,
        last_update_time: None,
        version: None,
    }
}

fn sample_app() -> AppSummary {
    AppSummary {
        app_id: "org.example.dolphin".to_string(),
        package_name: Some("org.example.dolphin".to_string()),
        name: "Dolphin".to_string(),
        user: "Example Team".to_string(),
        repositories: "dolphin".to_string(),
        icon: "https://example.test/dolphin.png".to_string(),
        des: "Flipper-powered browser".to_string(),
        readme: Some("# Dolphin".to_string()),
        category: Some(vec!["tools".to_string()]),
        extra: None,
    }
}

fn seeded_fallback() -> Arc<InMemoryChannelDriver> {
    Arc::new(
        InMemoryChannelDriver::new(key("js.fallback"), meta())
            .with_apps(vec![sample_app()])
            .with_config(Some(ChannelConfig {
                version: "7".to_string(),
                proxy: Some("https://proxy.test".to_string()),
            })),
    )
}

fn channel_with_fallback(script: &str, fallback: Arc<InMemoryChannelDriver>) -> ScriptChannel {
    ScriptChannel::new(
        ScriptChannelConfig::new(key("js.fallback"), script, fake_host()).with_fallback(fallback),
    )
    .expect("script channel constructs")
}

#[test]
fn script_channel_fallback_reads_delegate_and_do_update_preserves_data() {
    let fallback = seeded_fallback();
    let channel = channel_with_fallback(NULL_JS, Arc::clone(&fallback));

    let apps = channel.get_all_apps(true).expect("fallback getAllApps");
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].app_id, "org.example.dolphin");

    let search = channel
        .search_apps("dolphin", true)
        .expect("fallback searchApps");
    assert_eq!(search.len(), 1);

    let info = channel
        .get_app_info("org.example.dolphin", true)
        .expect("fallback getAppInfo");
    assert_eq!(info.name, "Dolphin");

    let detail = channel
        .get_app_detail("org.example.dolphin", true)
        .expect("fallback getAppDetail");
    assert_eq!(detail.name, "Dolphin");
    assert_eq!(detail.package_name.as_deref(), Some("org.example.dolphin"));

    let update = channel
        .check_app_update("org.example.dolphin")
        .expect("fallback checkAppUpdate");
    assert_eq!(update.app_id, "org.example.dolphin");
    assert_eq!(update.name, "Dolphin");

    assert!(!channel.check_update().expect("fallback checkUpdate"));

    let config = channel
        .get_config(true)
        .expect("fallback getConfig")
        .expect("fallback config");
    assert_eq!(config.version, "7");
    assert_eq!(config.proxy.as_deref(), Some("https://proxy.test"));

    // Dart's doUpdate fallback pulls the full list and persists it. Core
    // delegates to the same-key driver and must never purge existing rows.
    assert!(channel.do_update(None).expect("fallback doUpdate"));
    let preserved = fallback.get_all_apps(false).expect("fallback still seeded");
    assert_eq!(preserved.len(), 1);
    assert_eq!(preserved[0].app_id, "org.example.dolphin");
    assert_eq!(preserved[0].name, "Dolphin");

    let before = fallback.get_all_apps(false).expect("pre-dispose apps");
    channel.dispose().expect("dispose");
    let after = fallback.get_all_apps(false).expect("post-dispose apps");
    assert_eq!(before, after);
}

#[test]
fn script_channel_fallback_missing_main_uses_fallback() {
    let fallback = seeded_fallback();
    let channel = channel_with_fallback(MISSING_MAIN_JS, Arc::clone(&fallback));

    let apps = channel
        .get_all_apps(false)
        .expect("script without main falls back");
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].app_id, "org.example.dolphin");

    channel.dispose().expect("dispose");
}

#[test]
fn script_channel_fallback_without_fallback_returns_typed_errors() {
    let channel = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.fallback"),
        NULL_JS,
        fake_host(),
    ))
    .expect("script channel constructs");

    assert_eq!(channel.get_all_apps(false).unwrap_err().code(), "not_found");
    assert_eq!(
        channel.search_apps("dolphin", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        channel.get_app_info("app", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        channel.get_app_detail("app", false).unwrap_err().code(),
        "not_found"
    );
    assert_eq!(
        channel.check_app_update("app").unwrap_err().code(),
        "not_found"
    );
    assert!(!channel.check_update().expect("no update by default"));
    assert!(!channel.do_update(None).expect("doUpdate no-op"));
    assert_eq!(channel.get_config(false).unwrap_err().code(), "unsupported");

    channel.dispose().expect("dispose");
}

#[test]
fn script_channel_fallback_envelope_and_type_errors_are_typed() {
    let error_channel = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.fallback"),
        ERROR_ENVELOPE_JS,
        fake_host(),
    ))
    .expect("error script channel constructs");
    let error = error_channel
        .get_all_apps(false)
        .expect_err("ok:false is an error");
    assert_eq!(error.code(), "internal");
    assert!(error.message().contains("boom"));

    let wrong_channel = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.fallback"),
        WRONG_TYPE_JS,
        fake_host(),
    ))
    .expect("wrong-type channel constructs");
    assert_eq!(
        wrong_channel.get_all_apps(false).unwrap_err().code(),
        "serialization"
    );
    assert_eq!(
        wrong_channel.check_update().unwrap_err().code(),
        "serialization"
    );

    let throwing = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.fallback"),
        THROWING_JS,
        fake_host(),
    ))
    .expect("throwing channel constructs");
    assert_eq!(throwing.get_all_apps(false).unwrap_err().code(), "internal");

    error_channel.dispose().expect("error channel dispose");
    wrong_channel.dispose().expect("wrong channel dispose");
    throwing.dispose().expect("throwing channel dispose");
}
