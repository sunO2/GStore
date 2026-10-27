//! ScriptDetail dispatch parity (page-scoped detail runtime).

mod support;

use gstore_core::channel::{ScriptDetail, ScriptDetailConfig, VersionOptionsQuery};
use gstore_core::dto::ChannelKey;
use serde_json::{json, Map, Value as JsonValue};
use support::fake_host;

fn key(value: &str) -> ChannelKey {
    ChannelKey::new(value).expect("valid channel key")
}

#[test]
fn script_channel_example_detail_dispatch() {
    const DETAIL_JS: &str = r#"
async function main(method, params) {
  params = params || {};
  switch (method) {
    case 'versionOptions':
      return { ok: true, data: {
        envs: ['prod'],
        versions: [{ version: '2.1.0', envs: ['prod'], buildCount: 1 }],
        currentEnv: 'prod',
        currentVersion: '2.1.0',
        params: params,
      } };
    case 'switchVersion':
      return { ok: true, data: {
        appId: params.appId,
        env: params.env,
        version: params.version,
        build: params.build || null,
        description: 'switched',
        downloads: [],
      } };
    case 'buildHistory':
      return { ok: true, data: {
        builds: [{ num: 7, publishedAt: 1700000000000, size: 10, changelog: 'fix', installTimes: 2, builtBy: 'ci', ipaName: 'a.ipa' }],
        params: params,
      } };
    case 'detailMenu':
      return { ok: true, data: [
        { action: '版本切换', jscall: 'showVersionPicker', icon: 'versions', clickIsDimiss: true },
        { jscall: 'history' },
      ] };
    default:
      return null;
  }
}
"#;
    let host = fake_host();
    let detail = ScriptDetail::new(ScriptDetailConfig::new(key("js.example"), DETAIL_JS, host))
        .expect("detail channel");

    let options = detail
        .version_options(VersionOptionsQuery {
            app_id: "org.example.dolphin",
            env: Some("prod"),
            version: None,
        })
        .expect("versionOptions")
        .expect("versionOptions data");
    assert_eq!(
        options["params"],
        json!({"appId": "org.example.dolphin", "env": "prod"})
    );

    let filtered = detail
        .version_options(VersionOptionsQuery {
            app_id: "org.example.dolphin",
            env: None,
            version: Some("2.1.0"),
        })
        .expect("versionOptions with version")
        .expect("versionOptions data");
    assert_eq!(
        filtered["params"],
        json!({"appId": "org.example.dolphin", "version": "2.1.0"})
    );

    let mut build = Map::new();
    build.insert("num".to_string(), JsonValue::from(7));
    build.insert("ipaName".to_string(), JsonValue::String("a.ipa".into()));
    let switched = detail
        .switch_version(gstore_core::SwitchVersionQuery {
            app_id: "org.example.dolphin",
            env: "prod",
            version: "2.1.0",
            build: Some(&build),
        })
        .expect("switchVersion")
        .expect("switchVersion data");
    assert_eq!(switched["env"], json!("prod"));
    assert_eq!(switched["build"], json!({"num": 7, "ipaName": "a.ipa"}));

    let history = detail
        .build_history(gstore_core::BuildHistoryQuery {
            app_id: "org.example.dolphin",
            env: "prod",
            version: "2.1.0",
        })
        .expect("buildHistory")
        .expect("buildHistory data");
    assert_eq!(
        history["params"],
        json!({"appId": "org.example.dolphin", "version": "2.1.0", "env": "prod"})
    );

    let menu = detail
        .detail_menu("org.example.dolphin")
        .expect("detailMenu");
    assert_eq!(menu.len(), 2);
    assert_eq!(menu[0].action, "版本切换");
    assert_eq!(menu[0].jscall, "showVersionPicker");
    assert_eq!(menu[0].icon.as_deref(), Some("versions"));
    assert_eq!(menu[0].click_is_dimiss, Some(true));
    assert_eq!(menu[0].label(), "版本切换");
    assert_eq!(menu[1].label(), "history");

    detail.dispose().expect("first detail dispose");
    detail.dispose().expect("detail dispose is idempotent");
    let disposed = detail
        .version_options(VersionOptionsQuery {
            app_id: "a",
            env: None,
            version: None,
        })
        .expect_err("disposed detail errors");
    assert_eq!(disposed.code(), "internal");
}

#[test]
fn detail_no_result_states_degrade_to_none() {
    const NO_RESULT_JS: &str = r#"
async function main(method) {
  if (method === 'throw') throw new Error('kaboom');
  if (method === 'okFalse') return { ok: false, error: 'boom' };
  if (method === 'nonList') return { ok: true, data: 'not-a-list' };
  return null;
}
"#;
    let detail = ScriptDetail::new(ScriptDetailConfig::new(
        key("js.noresult"),
        NO_RESULT_JS,
        fake_host(),
    ))
    .expect("detail channel");

    for method in ["null", "throw", "okFalse"] {
        let outcome = detail
            .call_main(method, &Map::new())
            .expect("no-result is not an error");
        assert!(outcome.is_none(), "{method} must yield None");
    }

    assert!(detail.detail_menu("app").expect("non-list menu").is_empty());

    let options = detail
        .version_options(VersionOptionsQuery {
            app_id: "app",
            env: None,
            version: Some("1.0"),
        })
        .expect("versionOptions degrades");
    assert!(options.is_none());

    detail.dispose().expect("dispose");
}
