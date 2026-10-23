//! Exact `main(method, params)` maps for every ChannelDriver read/update method.

mod support;

use gstore_core::channel::{ChannelDriver, ScriptChannel};
use gstore_core::dto::ChannelKey;
use gstore_core::ScriptChannelConfig;
use support::{fake_host, HostCall};

const PARAMS_JS: &str = r#"
async function main(method, params) {
  params = params || {};
  host.log.info(method + '|' + JSON.stringify(params));
  switch (method) {
    case 'getAllApps':
    case 'searchApps':
      return { ok: true, data: [] };
    case 'getAppInfo':
    case 'getAppDetail':
    case 'checkAppUpdate':
      return { ok: true, data: { appId: 'org.example.dolphin', name: 'Dolphin' } };
    case 'checkUpdate':
    case 'doUpdate':
      return { ok: true, data: false };
    case 'getConfig':
      return { ok: true, data: { version: '1' } };
    default:
      return null;
  }
}
"#;

fn key(value: &str) -> ChannelKey {
    ChannelKey::new(value).expect("valid channel key")
}

#[test]
fn script_channel_example_param_maps_match_dart() {
    let host = fake_host();
    let channel = ScriptChannel::new(ScriptChannelConfig::new(
        key("js.params"),
        PARAMS_JS,
        host.clone(),
    ))
    .expect("params channel");

    assert!(channel.get_all_apps(true).expect("getAllApps").is_empty());
    assert!(channel
        .search_apps("dolphin", false)
        .expect("searchApps")
        .is_empty());
    channel
        .get_app_info("org.example.dolphin", false)
        .expect("getAppInfo");
    channel
        .get_app_detail("org.example.dolphin", true)
        .expect("getAppDetail");
    channel
        .check_app_update("org.example.dolphin")
        .expect("checkAppUpdate");
    assert!(!channel.check_update().expect("checkUpdate"));
    assert!(!channel.do_update(None).expect("doUpdate"));
    channel.get_config(false).expect("getConfig");

    let messages: Vec<String> = host
        .calls()
        .into_iter()
        .filter_map(|call| match call {
            HostCall::Log { channel, message } if channel == "js.params" => Some(message),
            _ => None,
        })
        .collect();
    assert_eq!(
        messages,
        vec![
            "getAllApps|{\"forceRefresh\":true}",
            "searchApps|{\"keyword\":\"dolphin\"}",
            "getAppInfo|{\"appId\":\"org.example.dolphin\"}",
            "getAppDetail|{\"appId\":\"org.example.dolphin\"}",
            "checkAppUpdate|{\"appId\":\"org.example.dolphin\"}",
            "checkUpdate|{}",
            "doUpdate|{}",
            "getConfig|{}",
        ]
    );

    channel.dispose().expect("dispose");
}
